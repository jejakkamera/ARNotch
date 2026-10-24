import AppKit
import UniformTypeIdentifiers

/// Turns dropped item providers into file URLs. Files pass through (copied first when they live in a temporary
/// folder the source may clean up); text, web links and images are written to a directory first. All loading,
/// copying and writing happens on NSItemProvider's background queues.
enum ShelfDropLoader {
    static let acceptedTypes: [UTType] = [.fileURL, .url, .image, .plainText]

    static func canLoad(_ provider: NSItemProvider) -> Bool {
        acceptedTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
    }

    /// Loads every provider concurrently and calls `completion` on the main actor with the resulting files, in drop order.
    static func load(
        _ providers: [NSItemProvider],
        writingInto directory: URL,
        completion: @escaping @MainActor @Sendable ([URL]) -> Void
    ) {
        let results = ResultSlots(count: providers.count)
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            let steps = Step.allCases.filter { $0.applies(to: provider) }
            attempt(steps[...], provider: ProviderBox(provider), name: provider.suggestedName, directory: directory) { url in
                results.set(url, at: index)
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(results.urls) }
        }
    }

    // MARK: Strategies

    /// Ways to read a provider, most faithful first; the next one is tried when one fails.
    private enum Step: CaseIterable {
        case file, image, link, text

        func applies(to provider: NSItemProvider) -> Bool {
            switch self {
            case .file: provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            case .image: provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            case .link: provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            case .text: provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            }
        }
    }

    private static func attempt(
        _ steps: ArraySlice<Step>,
        provider box: ProviderBox,
        name: String?,
        directory: URL,
        done: @escaping @Sendable (URL?) -> Void
    ) {
        guard let step = steps.first else { return done(nil) }
        let next: @Sendable (URL?) -> Void = { url in
            if let url { done(url) } else {
                attempt(steps.dropFirst(), provider: box, name: name, directory: directory, done: done)
            }
        }
        let provider = box.provider

        switch step {
        case .file:
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                next(url.flatMap { adopt($0, into: directory) })
            }
        case .image:
            guard let type = provider.registeredTypeIdentifiers.compactMap(UTType.init).first(where: { $0.conforms(to: .image) })
            else { return next(nil) }
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                let png = data.flatMap { type.conforms(to: .png) ? $0 : pngData(from: $0) }
                next(png.flatMap { write($0, base: baseName(name) ?? "Image", ext: "png", in: directory) })
            }
        case .link:
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return next(nil) }
                if url.isFileURL { return next(adopt(url, into: directory)) }
                next(weblocData(for: url).flatMap {
                    write($0, base: baseName(name) ?? url.host() ?? "Link", ext: "webloc", in: directory)
                })
            }
        case .text:
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return next(nil) }
                next(write(Data(text.utf8), base: textTitle(text), ext: "txt", in: directory))
            }
        }
    }

    // MARK: Writing

    /// Resolves file reference URLs (file:///.file/id=…) to real paths, and copies files the drag source keeps
    /// in a temporary folder (e.g. the screenshot thumbnail) into `directory` before the source deletes them.
    private static func adopt(_ url: URL, into directory: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let file = (url as NSURL).filePathURL ?? url
        guard isTemporary(file), !isInside(file, directory) else { return file }
        let ext = file.pathExtension
        let base = sanitized(file.deletingPathExtension().lastPathComponent) ?? "File"
        // If the copy fails, keep the reference; pruneMissing drops it once the file is gone.
        return createUnique(base: base, ext: ext, in: directory) {
            try FileManager.default.copyItem(at: file, to: $0)
        } ?? file
    }

    private static func isTemporary(_ url: URL) -> Bool {
        let components = url.pathComponents
        if components.contains("TemporaryItems") || components.contains(where: { $0.hasPrefix("NSIRD_") }) {
            return true
        }
        return isInside(url, FileManager.default.temporaryDirectory)
    }

    private static func isInside(_ url: URL, _ directory: URL) -> Bool {
        // resolvingSymlinksInPath also folds /private/var into /var, so both sides compare alike.
        let path = url.resolvingSymlinksInPath().path
        let dir = directory.resolvingSymlinksInPath().path
        return path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
    }

    private static func pngData(from data: Data) -> Data? {
        if let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        // Vector or exotic formats: rasterise through NSImage.
        guard let tiff = NSImage(data: data)?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    private static func weblocData(for url: URL) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
    }

    /// Writes `data` under a name that does not clash with existing files ("Name", "Name 2", …).
    private static func write(_ data: Data, base: String, ext: String, in directory: URL) -> URL? {
        createUnique(base: base, ext: ext, in: directory) { try data.write(to: $0, options: .withoutOverwriting) }
    }

    /// Calls `create` with "Name.ext", "Name 2.ext", … until it succeeds without hitting an existing file.
    private static func createUnique(
        base: String,
        ext: String,
        in directory: URL,
        _ create: (URL) throws -> Void
    ) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        for attempt in 1...500 {
            let name = attempt == 1 ? base : "\(base) \(attempt)"
            var url = directory.appending(path: name)
            if !ext.isEmpty { url.appendPathExtension(ext) }
            do {
                try create(url)
                return url
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Filename-safe version of a suggested name, without its extension.
    private static func baseName(_ name: String?) -> String? {
        guard let name else { return nil }
        let stem = (name as NSString).deletingPathExtension
        return sanitized(stem.isEmpty ? name : stem)
    }

    /// First line of the text, shortened, as a filename.
    private static func textTitle(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return sanitized(String(firstLine.prefix(32))) ?? "Text"
    }

    private static func sanitized(_ name: String) -> String? {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? nil : String(cleaned.prefix(64))
    }
}

/// NSItemProvider is safe to use from its own completion handlers; this box lets it cross into them.
private struct ProviderBox: @unchecked Sendable {
    let provider: NSItemProvider
    init(_ provider: NSItemProvider) { self.provider = provider }
}

/// Thread-safe, index-addressed storage for concurrent load results.
private final class ResultSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [URL?]

    init(count: Int) { slots = Array(repeating: nil, count: count) }

    func set(_ url: URL?, at index: Int) {
        lock.withLock { slots[index] = url }
    }

    var urls: [URL] {
        lock.withLock { slots.compactMap { $0 } }
    }
}
