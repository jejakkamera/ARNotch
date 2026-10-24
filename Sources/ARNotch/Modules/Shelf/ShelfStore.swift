import AppKit
import SwiftUI

/// A file sitting on the shelf. Everything on the shelf is a file; dropped text, links and images are written to disk first.
struct ShelfItem: Identifiable, Hashable, Sendable {
    let url: URL

    init(url: URL) {
        self.url = url.standardizedFileURL
    }

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    /// True for files Crest generated itself (text snippets, links, images); those are deleted when removed.
    var isOwned: Bool { ShelfStore.owns(url) }
}

/// Ordered, persisted list of shelf files.
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = [] {
        didSet { if didLoad && items != oldValue { save() } }
    }

    var urls: [URL] { items.map(\.url) }
    var isEmpty: Bool { items.isEmpty }

    /// ~/Library/Application Support/Crest
    nonisolated static let supportDirectory = URL.applicationSupportDirectory
        .appending(path: "Crest", directoryHint: .isDirectory)
    /// Where dropped text, links and images are written.
    nonisolated static let storageDirectory = supportDirectory.appending(path: "Shelf", directoryHint: .isDirectory)
    /// Scratch folder for content dropped straight onto the AirDrop tile (never added to the shelf).
    nonisolated static let airDropStagingDirectory = FileManager.default.temporaryDirectory
        .appending(path: "Crest-AirDrop", directoryHint: .isDirectory)
    nonisolated private static let indexFile = supportDirectory.appending(path: "shelf.json")

    private let ioQueue = DispatchQueue(label: "Crest.Shelf.io", qos: .utility)
    private var didLoad = false

    private init() {
        load()
    }

    nonisolated static func owns(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(storageDirectory.standardizedFileURL.path + "/")
    }

    // MARK: Mutations

    /// Appends file URLs that are not on the shelf yet, keeping their order.
    func add(urls: [URL]) {
        var seen = Set(items.map(\.id))
        let new = urls.filter(\.isFileURL).map(ShelfItem.init).filter { seen.insert($0.id).inserted }
        guard !new.isEmpty else { return }
        items.append(contentsOf: new)
    }

    func remove(_ item: ShelfItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        deleteOwnedFiles([item])
    }

    func removeAll() {
        let removed = items
        items.removeAll()
        deleteOwnedFiles(removed)
    }

    /// Called by the root view when something is dropped anywhere on the notch. Returns true if accepted.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let accepted = providers.filter(ShelfDropLoader.canLoad)
        guard !accepted.isEmpty else { return false }
        ShelfDropLoader.load(accepted, writingInto: Self.storageDirectory) { [weak self] urls in
            self?.add(urls: urls)
        }
        return true
    }

    /// Drops items whose files were moved or deleted behind our back.
    func pruneMissing() {
        let paths = items.map(\.id)
        guard !paths.isEmpty else { return }
        ioQueue.async { [weak self] in
            let missing = Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
            guard !missing.isEmpty else { return }
            Task { @MainActor in
                self?.items.removeAll { missing.contains($0.id) }
            }
        }
    }

    // MARK: Persistence

    private func load() {
        let file = Self.indexFile
        let storage = Self.storageDirectory
        let staging = Self.airDropStagingDirectory
        let launchDate = Date()
        ioQueue.async { [weak self] in
            let fm = FileManager.default
            try? fm.removeItem(at: staging)
            let saved: [String]
            let indexIsValid: Bool
            do {
                saved = try JSONDecoder().decode([String].self, from: Data(contentsOf: file))
                indexIsValid = true
            } catch CocoaError.fileReadNoSuchFile {
                saved = []
                indexIsValid = true
            } catch {
                // Never treat an unreadable index as empty: orphan cleanup would delete every saved snippet.
                // Recover the files we generated instead and write a fresh index.
                NSLog("Crest Shelf: could not read shelf index, recovering saved files: \(error.localizedDescription)")
                indexIsValid = false
                saved = ((try? fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                    .map(\.standardizedFileURL.path)
                    .sorted()
            }
            let existing = saved.filter { fm.fileExists(atPath: $0) }
            if indexIsValid {
                Self.removeOrphans(in: storage, keeping: Set(existing), createdBefore: launchDate)
            }
            let urls = existing.map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                self?.finishLoading(urls, rewriteIndex: !indexIsValid)
            }
        }
    }

    private func finishLoading(_ saved: [URL], rewriteIndex: Bool) {
        // Anything dropped while the index was loading goes after the saved items.
        let savedItems = saved.map(ShelfItem.init)
        var seen = Set<String>()
        let merged = (savedItems + items).filter { seen.insert($0.id).inserted }
        items = merged
        didLoad = true
        // The didSet skipped those early drops (and may see no change now), so write the index explicitly;
        // otherwise the next launch would treat their generated files as orphans.
        if merged != savedItems || rewriteIndex { save() }
    }

    private func save() {
        let paths = items.map(\.id)
        let file = Self.indexFile
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(paths).write(to: file, options: .atomic)
            } catch {
                NSLog("Crest Shelf: could not save shelf index: \(error.localizedDescription)")
            }
        }
    }

    private func deleteOwnedFiles(_ removed: [ShelfItem]) {
        // Generated names get reused ("Text 2.txt"), so forget their thumbnails too.
        ShelfThumbnails.evict(removed.map(\.url))
        let owned = removed.filter(\.isOwned).map(\.url)
        guard !owned.isEmpty else { return }
        ioQueue.async {
            owned.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    /// Removes generated files left behind by earlier sessions (e.g. after a crash).
    nonisolated private static func removeOrphans(in directory: URL, keeping kept: Set<String>, createdBefore date: Date) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .attributeModificationDateKey]
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        for url in contents where !kept.contains(url.standardizedFileURL.path) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            // Copies of dropped temporary files may keep their source's creation date; the status-change
            // date still shows they were made this session.
            let newest = [values?.creationDate, values?.attributeModificationDate].compactMap { $0 }.max()
            if let newest, newest < date { try? fm.removeItem(at: url) }
        }
    }
}
