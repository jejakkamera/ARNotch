import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: AppSettings

    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.78)
    private let closeAnimation = Animation.spring(response: 0.38, dampingFraction: 1.0)

    var body: some View {
        let shape = NotchShape(
            topRadius: vm.isOpen ? NotchMetrics.openTopRadius : NotchMetrics.closedTopRadius,
            bottomRadius: vm.isOpen ? NotchMetrics.openBottomRadius : NotchMetrics.closedBottomRadius
        )
        let size = vm.shapeSize

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape.fill(Color.black)

                if vm.isOpen {
                    OpenNotchContent()
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)).animation(openAnimation.delay(0.05)),
                            removal: .opacity.animation(.easeOut(duration: 0.12))
                        ))
                } else {
                    ClosedNotchContent()
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay {
                // The Shelf draws its own drop target. Elsewhere, outline only the sides and bottom: the path's
                // top edge and ears sit on the screen edge and menu bar.
                if vm.isDropTargeted && vm.tab != .shelf {
                    shape.stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .mask(Rectangle().padding(.top, NotchMetrics.openTopRadius).padding([.horizontal, .bottom], -2))
                }
            }
            .shadow(color: .black.opacity(vm.isOpen ? 0.55 : 0), radius: 14, y: 4)
            .contentShape(shape)
            .onDrop(of: [.fileURL, .url, .image, .plainText], isTargeted: $vm.isDropTargeted) { providers in
                vm.open(tab: .shelf)
                return ShelfStore.shared.handleDrop(providers)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(vm.isOpen ? openAnimation : closeAnimation, value: vm.isOpen)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: vm.tab)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vm.closedActivity)
        .preferredColorScheme(.dark)
    }
}

// MARK: Closed state

/// Live activity "wings" on each side of the hardware notch.
struct ClosedNotchContent: View {
    @EnvironmentObject private var vm: NotchViewModel

    var body: some View {
        HStack(spacing: 0) {
            wing(leading: true)
            Spacer(minLength: vm.notchSize.width)
            wing(leading: false)
        }
        .frame(height: vm.notchSize.height)
    }

    @ViewBuilder
    private func wing(leading: Bool) -> some View {
        Group {
            switch vm.closedActivity {
            case .media:
                if leading { MediaLiveActivityLeading() } else { MediaLiveActivityTrailing() }
            case .charging:
                if leading { BatteryLiveActivityLeading() } else { BatteryLiveActivityTrailing() }
            case .timer:
                if leading { TimerLiveActivityLeading() } else { TimerLiveActivityTrailing() }
            case .ports:
                if leading { DevPortsLiveActivityLeading() } else { DevPortsLiveActivityTrailing() }
            case .pomodoro:
                if leading { PomodoroLiveActivityLeading() } else { PomodoroLiveActivityTrailing() }
            case .blank:
                if leading { DisplayBlankLiveActivityLeading() } else { DisplayBlankLiveActivityTrailing() }
            case .none:
                EmptyView()
            }
        }
        .frame(width: vm.closedWingWidth, height: vm.notchSize.height)
        .transition(.opacity.combined(with: .scale(scale: 0.6)))
    }
}

// MARK: Open state

struct OpenNotchContent: View {
    @EnvironmentObject private var vm: NotchViewModel

    var body: some View {
        VStack(spacing: 8) {
            NotchHeaderView()
                .frame(height: vm.notchSize.height)

            Group {
                switch vm.tab {
                case .home: HomeTabView()
                case .shelf: ShelfView()
                case .timer: TimerTabView()
                case .system: SystemTabView { DevPortsListView() }
                case .connectivity: ConnectivityTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, NotchMetrics.openTopRadius + 16)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
    }
}

/// Header row: tabs on the left, status + settings on the right; the middle stays clear for the hardware notch.
struct NotchHeaderView: View {
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        // Left and right clusters each get exactly the space beside the hardware notch.
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(NotchTab.allCases) { tab in
                    tabButton(tab)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: vm.notchSize.width + 12)

            HStack(spacing: 6) {
                if settings.showBatteryInHeader {
                    BatteryIndicatorView()
                }
                Button {
                    AppDelegate.shared?.openSettings()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.top, 2)
    }

    private func tabButton(_ tab: NotchTab) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { vm.tab = tab }
        } label: {
            // Only the selected tab shows its title, so all tabs stay clear of the hardware notch.
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                if vm.tab == tab {
                    Text(tab.title).fixedSize()
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(vm.tab == tab ? Color.white.opacity(0.16) : Color.clear)
            )
            .foregroundStyle(vm.tab == tab ? Color.white : Color.white.opacity(0.55))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }
}

struct HomeTabView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        // Top-aligned so the month label, mirror tile and artwork line up whatever the media state.
        HStack(alignment: .top, spacing: 14) {
            MediaPlayerView()
                .frame(maxWidth: .infinity)
            if settings.showCalendar {
                Divider().overlay(Color.white.opacity(0.12))
                CalendarWidgetView()
                    .frame(width: 170)
            }
            if settings.showMirror {
                MirrorWidgetView()
                    .frame(width: 120, height: 120)
            }
        }
    }
}
