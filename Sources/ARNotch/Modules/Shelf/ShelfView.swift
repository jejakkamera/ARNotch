import AppKit
import SwiftUI

private enum ShelfLayout {
    /// Height of the item row and the side tiles, centred in the ~140 pt content area.
    static let height: CGFloat = 112
    static let sideTileWidth: CGFloat = 80
    static let tileWidth: CGFloat = 64
    static let tileSpacing: CGFloat = 4
    static let rowPadding: CGFloat = 6
}

/// Content of the Shelf tab (full open-notch content area, ~600×140 pt).
struct ShelfView: View {
    @EnvironmentObject private var vm: NotchViewModel
    @ObservedObject private var store = ShelfStore.shared

    private let menuBegan = NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
    private let menuEnded = NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if store.items.isEmpty {
                    ShelfEmptyState(isTargeted: vm.isDropTargeted)
                        .transition(.opacity)
                } else {
                    ShelfItemsRow(items: store.items, isTargeted: vm.isDropTargeted)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                ShelfAirDropTile(urls: store.urls)
                ShelfActionsColumn(urls: store.urls)
            }
        }
        .frame(height: ShelfLayout.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: store.items)
        .onReceive(menuBegan) { _ in ShelfKeepOpen.shared.menuDidBeginTracking(on: vm) }
        .onReceive(menuEnded) { _ in ShelfKeepOpen.shared.menuDidEndTracking() }
        .onAppear { store.pruneMissing() }
        .onDisappear { ShelfKeepOpen.shared.releaseAll() }
    }
}

// MARK: Empty state

private struct ShelfEmptyState: View {
    let isTargeted: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        shape
            .fill(Color.white.opacity(isTargeted ? 0.08 : 0.03))
            .overlay {
                shape.strokeBorder(
                    Color.white.opacity(isTargeted ? 0.6 : 0.2),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
            }
            .overlay {
                VStack(spacing: 5) {
                    Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                        .font(.system(size: 22, weight: .medium))
                        .symbolEffect(.bounce, value: isTargeted)
                        .padding(.bottom, 2)
                    Text("Drop files here")
                        .font(.system(size: 12, weight: .semibold))
                    Text("They stay on the shelf until you remove them")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .foregroundStyle(Color.white.opacity(isTargeted ? 0.95 : 0.65))
            }
            .scaleEffect(isTargeted ? 1.015 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
    }
}

// MARK: Items

private struct ShelfItemsRow: View {
    let items: [ShelfItem]
    let isTargeted: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ShelfLayout.tileSpacing) {
                        ForEach(items) { item in
                            ShelfItemTile(item: item)
                                .id(item.id)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, ShelfLayout.rowPadding)
                    .frame(maxHeight: .infinity)
                }
                .onChange(of: items.count) { oldCount, newCount in
                    guard newCount > oldCount, let last = items.last else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .trailing) }
                }
            }
            // Scroll indicators are hidden, so fade both edges when items overflow to show there is more.
            .mask(ShelfEdgeFade(isActive: contentWidth > geo.size.width + 0.5, width: geo.size.width))
        }
        .background(shape.fill(Color.white.opacity(isTargeted ? 0.07 : 0.03)))
        .overlay {
            if isTargeted {
                shape.strokeBorder(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            }
        }
        .clipShape(shape)
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }

    private var contentWidth: CGFloat {
        let count = CGFloat(items.count)
        return count * ShelfLayout.tileWidth + max(0, count - 1) * ShelfLayout.tileSpacing + ShelfLayout.rowPadding * 2
    }
}

/// Opaque mask whose leading and trailing edges fade out while `isActive`.
private struct ShelfEdgeFade: View {
    let isActive: Bool
    let width: CGFloat

    var body: some View {
        if isActive, width > 0 {
            let fade = min(0.2, 16 / width)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: fade),
                    .init(color: .black, location: 1 - fade),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            Color.black
        }
    }
}

private struct ShelfItemTile: View {
    let item: ShelfItem

    @EnvironmentObject private var vm: NotchViewModel
    private let hover = State(initialValue: false)
    private let anchorState = State(initialValue: ShelfViewAnchor())
    private var hovering: Bool { hover.wrappedValue }
    private var anchor: ShelfViewAnchor { anchorState.wrappedValue }

    var body: some View {
        VStack(spacing: 4) {
            ShelfThumbnailView(url: item.url)
                .frame(width: 46, height: 46)
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        removeButton
                            .offset(x: 7, y: -5)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }

            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(width: 60, height: 26, alignment: .top)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(width: ShelfLayout.tileWidth)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.1 : 0))
        )
        .background(ShelfAnchorView(anchor: anchor))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.12)) { hover.wrappedValue = isHovering }
        }
        .onTapGesture(count: 2) { ShelfActions.open(item.url) }
        .onDrag {
            ShelfDragOut.shared.begin(viewModel: vm)
            return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Open") { ShelfActions.open(item.url) }
            Button("Show in Finder") { ShelfActions.revealInFinder([item.url]) }
            Button("Copy") { ShelfActions.copy([item.url]) }
            Button("Share…") { ShelfSharePicker.shared.show([item.url], from: anchor.view, viewModel: vm) }
            Divider()
            Button("Remove") { ShelfStore.shared.remove(item) }
        }
        .help(item.name)
    }

    private var removeButton: some View {
        Button {
            ShelfStore.shared.remove(item)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(Color.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color(white: 0.28)))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Remove from Shelf")
    }
}

private struct ShelfThumbnailView: View {
    let url: URL

    @Environment(\.displayScale) private var displayScale
    private let imageState: State<NSImage?>

    init(url: URL) {
        self.url = url
        imageState = State(initialValue: ShelfThumbnails.cached(url))
    }

    private var image: NSImage? {
        get { imageState.wrappedValue }
        nonmutating set { imageState.wrappedValue = newValue }
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        if let cached = ShelfThumbnails.cached(url) {
            image = cached
            return
        }
        let icon = await ShelfThumbnails.icon(for: url)
        guard !Task.isCancelled else { return }
        if image == nil { image = icon }

        let side: CGFloat = 46
        let thumbnail = await ShelfThumbnails.thumbnail(for: url, size: CGSize(width: side, height: side), scale: displayScale)
        guard !Task.isCancelled else { return }
        let best = thumbnail ?? icon
        image = best
        ShelfThumbnails.store(best, for: url)
    }
}

// MARK: Side tiles

private struct ShelfAirDropTile: View {
    let urls: [URL]

    private let targeted = State(initialValue: false)
    private let hover = State(initialValue: false)
    private var isTargeted: Bool { targeted.wrappedValue }
    private var hovering: Bool { hover.wrappedValue }

    var body: some View {
        Button {
            ShelfActions.airDrop(urls)
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color(red: 0.32, green: 0.66, blue: 1), Color(red: 0.04, green: 0.42, blue: 0.96)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .symbolEffect(.variableColor.iterative, isActive: isTargeted)
                }
                .frame(width: 38, height: 38)
                .scaleEffect(isTargeted ? 1.12 : 1)

                VStack(spacing: 1) {
                    Text("AirDrop")
                        .font(.system(size: 11, weight: .semibold))
                    Text(isTargeted ? "Release to send" : "Drop to send")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .frame(width: ShelfLayout.sideTileWidth, height: ShelfLayout.height)
            .background(ShelfTileBackground(highlighted: isTargeted, hovering: hovering, tint: .blue))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(ShelfPressStyle())
        .onHover { hover.wrappedValue = $0 }
        .onDrop(of: ShelfDropLoader.acceptedTypes, isTargeted: targeted.projectedValue) { providers in
            let accepted = providers.filter(ShelfDropLoader.canLoad)
            if !accepted.isEmpty {
                ShelfDropLoader.load(accepted, writingInto: ShelfStore.airDropStagingDirectory) { urls in
                    ShelfActions.airDrop(urls)
                }
            }
            // Always claim the drop so the notch-wide handler does not also put it on the shelf.
            return true
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
        .help(urls.isEmpty ? "Drop files here to AirDrop them" : "AirDrop everything on the shelf")
    }
}

private struct ShelfActionsColumn: View {
    let urls: [URL]

    @EnvironmentObject private var vm: NotchViewModel
    private let shareAnchorState = State(initialValue: ShelfViewAnchor())
    private let confirmState = State(initialValue: false)
    private var shareAnchor: ShelfViewAnchor { shareAnchorState.wrappedValue }

    /// First click on Clear arms it; a second click within a few seconds clears the shelf.
    private var confirmingClear: Bool {
        get { confirmState.wrappedValue }
        nonmutating set { confirmState.wrappedValue = newValue }
    }

    var body: some View {
        VStack(spacing: 8) {
            ShelfSmallTile(symbol: "square.and.arrow.up", title: "Share") {
                ShelfSharePicker.shared.show(urls, from: shareAnchor.view, viewModel: vm)
            }
            .background(ShelfAnchorView(anchor: shareAnchor))
            .help("Share everything on the shelf")

            ShelfSmallTile(
                symbol: confirmingClear ? "trash.fill" : "trash",
                title: confirmingClear ? "Confirm" : "Clear",
                tint: confirmingClear ? .red : nil
            ) {
                if confirmingClear {
                    confirmingClear = false
                    ShelfStore.shared.removeAll()
                } else {
                    confirmingClear = true
                }
            }
            .help(confirmingClear ? "Click again to clear the shelf" : "Clear the shelf")
        }
        .frame(width: ShelfLayout.sideTileWidth, height: ShelfLayout.height)
        .disabled(urls.isEmpty)
        .opacity(urls.isEmpty ? 0.35 : 1)
        .animation(.easeOut(duration: 0.15), value: confirmingClear)
        .task(id: confirmingClear) {
            guard confirmingClear else { return }
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { confirmingClear = false }
        }
        .onChange(of: urls.isEmpty) { _, isEmpty in
            if isEmpty { confirmingClear = false }
        }
    }
}

private struct ShelfSmallTile: View {
    let symbol: String
    let title: String
    var tint: Color?
    let action: () -> Void

    private let hover = State(initialValue: false)
    private var hovering: Bool { hover.wrappedValue }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint ?? Color.white.opacity(0.9))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ShelfTileBackground(highlighted: tint != nil, hovering: hovering, tint: tint ?? .white))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(ShelfPressStyle())
        .onHover { hover.wrappedValue = $0 }
    }
}

private struct ShelfTileBackground: View {
    let highlighted: Bool
    let hovering: Bool
    let tint: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        shape
            .fill(highlighted ? tint.opacity(0.22) : Color.white.opacity(hovering ? 0.12 : 0.07))
            .overlay {
                shape.strokeBorder(highlighted ? tint.opacity(0.7) : Color.white.opacity(0.06), lineWidth: 1)
            }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct ShelfPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
