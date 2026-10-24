import AppKit
import ApplicationServices
import Darwin

// Background sampling for the System module. Everything in this file runs off the main thread:
// `SystemSampler` is confined to the monitor's serial sampling queue and `SystemHangProbe` to its
// Accessibility queue. Every syscall may fail (processes exit between calls); failures are skipped.

// MARK: - Values

/// System-wide memory pressure as reported by the kernel.
enum SystemMemoryPressure: Int, Sendable {
    case normal, warning, critical

    var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }
}

/// Physical memory use, computed the way Activity Monitor's "Memory Used" is.
struct SystemMemoryUsage: Equatable, Sendable {
    /// App memory + wired + compressed, in bytes.
    var used: UInt64
    /// Installed RAM in bytes.
    var total: UInt64
    var pressure: SystemMemoryPressure

    /// Used share, 0...1.
    var fraction: Double { total > 0 ? min(max(Double(used) / Double(total), 0), 1) : 0 }
}

/// Bytes per second received and sent over the physical network interfaces.
struct SystemNetworkRate: Equatable, Sendable {
    var download: Double
    var upload: Double
}

/// One header-level reading. Rates are nil when there was no earlier reading to compare with.
struct SystemMetricsSample: Sendable {
    var cpu: Double?
    var memory: SystemMemoryUsage?
    var network: SystemNetworkRate?
}

/// CPU and memory of one app, one heavy loose process, or several light loose processes running the
/// same executable.
struct SystemProcessGroup: Sendable {
    enum Kind: Sendable, Equatable {
        /// The processes inside an `.app` bundle, plus the helpers that app is responsible for
        /// (WebKit and other XPC services, light child tools such as node or language servers).
        case bundle
        /// One process outside any `.app` that is heavy on its own (or whose row is held on screen).
        case process
        /// Light loose processes running the same executable, added up ("node ×26").
        case executable
    }

    /// Stable identity: the bundle path for apps, "pid:<pid>:<start>" for a loose process,
    /// "exe:<path>" for an executable's added-up processes.
    let key: String
    let kind: Kind
    /// The `.app` bundle the row stands for; nil for loose processes.
    let bundlePath: String?
    /// Bundle file name without ".app", or the executable name.
    let name: String
    let pids: [pid_t]
    /// The process a Quit acts on when no registered app does: the loose process itself, or the bundle's
    /// main executable (`Contents/MacOS/…`, e.g. a CLI shipped as an .app). Nil when only helpers run,
    /// and always nil for `.executable` rows (several processes are never signalled together).
    let leaderPID: pid_t?
    /// Start time (Mach absolute) of `leaderPID`, used to re-verify the pid before signalling it.
    let leaderStartTime: UInt64
    /// Executable path of `leaderPID`, re-checked before signalling (an exec changes it).
    let leaderPath: String?
    /// Percent of one core (can exceed 100 on multi-core); nil until two samples exist.
    let cpu: Double?
    /// Sum of physical footprints in bytes (Activity Monitor's "Memory" column).
    let memory: UInt64
    /// True when the leader's executable lives in a system location (never signalled).
    let isSystemPath: Bool
}

/// One sweep over the current user's processes.
struct SystemProcessSample: Sendable {
    var groups: [SystemProcessGroup]
    /// True when CPU values are deltas (second and later sweeps).
    var hasCPU: Bool
}

/// A running app as registered with LaunchServices, copied into plain values.
///
/// Every NSRunningApplication property read costs a synchronous LaunchServices round trip once the
/// main run loop has turned (about 15 ms for 130 apps), and `runningApplications` returns new
/// instances each time, so apps are captured off the main thread when the System tab appears and
/// every few seconds while it stays (Dock-icon changes post no notification), and kept current
/// from launch/terminate notifications in between.
struct SystemRunningApp: Equatable, Sendable {
    let pid: pid_t
    let bundlePath: String?
    let bundleIdentifier: String?
    let name: String?
    let isRegular: Bool
    let isFinishedLaunching: Bool

    init(_ app: NSRunningApplication) {
        pid = app.processIdentifier
        bundlePath = app.bundleURL?.path
        bundleIdentifier = app.bundleIdentifier
        name = app.localizedName
        isRegular = app.activationPolicy == .regular
        isFinishedLaunching = app.isFinishedLaunching
    }

    /// All running apps. NSRunningApplication is documented as safe to read from background threads.
    static func snapshot() -> [SystemRunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            app.isTerminated ? nil : SystemRunningApp(app)
        }
    }
}

// MARK: - Clock

enum SystemClock {
    /// Mach timebase; on Apple Silicon one tick is 125/3 ns, on Intel 1 ns.
    static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else { return (1, 1) }
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// Converts Mach absolute time units to nanoseconds without overflowing.
    static func nanoseconds(fromAbsolute ticks: UInt64) -> UInt64 {
        let (numer, denom) = timebase
        if numer == denom { return ticks }
        let (quotient, remainder) = ticks.quotientAndRemainder(dividingBy: denom)
        return quotient &* numer &+ (remainder &* numer) / denom
    }

    /// Monotonic now in nanoseconds (does not advance while asleep).
    static func now() -> UInt64 { nanoseconds(fromAbsolute: mach_absolute_time()) }
}

// MARK: - Sampler

/// Reads CPU, memory, network and per-process figures. Not thread-safe: use from one serial queue only.
final class SystemSampler: @unchecked Sendable {
    /// A loose process (outside any `.app`) gets a row of its own above these thresholds; below them it
    /// is credited to the app responsible for it, or added up with others running the same executable.
    static let looseProcessCPUThreshold = 5.0
    static let looseProcessMemoryThreshold: UInt64 = 300 * 1_000_000
    /// A loose process with its own row keeps it until it drops below these (so rows don't flicker).
    static let looseProcessCPUReleaseThreshold = 2.0
    static let looseProcessMemoryReleaseThreshold: UInt64 = 240 * 1_000_000

    private let host = mach_host_self()
    private let pageSize: UInt64 = {
        let size = UInt64(vm_kernel_page_size)
        return size > 0 ? size : 16_384
    }()
    private let physicalMemory = ProcessInfo.processInfo.physicalMemory
    private let userID = getuid()

    private var lastCPUTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var lastNetwork: (counters: [String: (rx: UInt64, tx: UInt64)], time: UInt64)?

    /// Bundle paths of the running regular (Dock) apps. An app nested in another app's bundle
    /// (Simulator or Instruments inside Xcode) gets its own row when it is listed here.
    /// Set from the owner through the sampling queue.
    var registeredAppBundles: Set<String> = []
    /// Row keys held on screen: a held loose process keeps its own row even after it turns light,
    /// and a held "exe:" row stays listed. Set from the owner through the sampling queue.
    var pinnedKeys: Set<String> = []

    private struct ProcessRecord {
        var startTime: UInt64
        var cpuTime: UInt64
        /// `pbsi_comm`; a change means the process exec'd another program (pid and start time stay).
        var command: String
        var path: String?
        /// `.app` bundles in `path`, outermost first.
        var bundles: [String]
        /// For a process outside any bundle: the `.app` bundles in the path of the process responsible
        /// for it (Safari for its WebKit processes, an IDE for its node children). Empty when none.
        var ownerBundles: [String]
        /// XPC services and executables in OS locations: always credited to the responsible app, since
        /// they can't be quit on their own.
        var isAlwaysCredited: Bool
        var name: String
        var isSystemPath: Bool
        /// A loose process currently heavy enough for its own row.
        var isPromoted = false
    }
    private var processRecords: [pid_t: ProcessRecord] = [:]
    /// Mach absolute time of the previous process sweep.
    private var lastProcessSweep: UInt64?

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    // MARK: Header metrics

    /// Forgets rate baselines, so the next reading starts fresh (used when sampling resumes after a pause).
    func resetMetricsBaseline() {
        lastCPUTicks = nil
        lastNetwork = nil
    }

    func sampleMetrics() -> SystemMetricsSample {
        SystemMetricsSample(cpu: sampleCPU(), memory: sampleMemory(), network: sampleNetwork())
    }

    /// Busy share of all cores since the previous call, 0...100, from host-wide tick counters.
    private func sampleCPU() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let ticks = (
            user: info.cpu_ticks.0,   // CPU_STATE_USER
            system: info.cpu_ticks.1, // CPU_STATE_SYSTEM
            idle: info.cpu_ticks.2,   // CPU_STATE_IDLE
            nice: info.cpu_ticks.3    // CPU_STATE_NICE
        )
        defer { lastCPUTicks = ticks }
        guard let last = lastCPUTicks else { return nil }

        // 32-bit counters wrap after weeks of uptime; wrapping subtraction keeps the delta right.
        let busy = Double(ticks.user &- last.user) + Double(ticks.system &- last.system) + Double(ticks.nice &- last.nice)
        let idle = Double(ticks.idle &- last.idle)
        guard busy + idle > 0 else { return nil }
        return min(max(busy / (busy + idle) * 100, 0), 100)
    }

    private func sampleMemory() -> SystemMemoryUsage? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appPages = anonymous > purgeable ? anonymous - purgeable : 0
        let usedPages = appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let used = min(usedPages * pageSize, physicalMemory)
        return SystemMemoryUsage(used: used, total: physicalMemory, pressure: Self.memoryPressure())
    }

    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    private static func memoryPressure() -> SystemMemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4...: return .critical
        case 2...3: return .warning
        default: return .normal
        }
    }

    /// Per-second throughput summed over physical interfaces, from 64-bit counters (NET_RT_IFLIST2).
    private func sampleNetwork() -> SystemNetworkRate? {
        guard let counters = Self.interfaceCounters() else { return nil }
        let now = SystemClock.now()
        defer { lastNetwork = (counters, now) }
        guard let last = lastNetwork, now > last.time else { return nil }

        let seconds = Double(now - last.time) / 1_000_000_000
        guard seconds > 0.05 else { return nil }
        let plausible = Self.maxPlausibleBytesPerSecond * seconds

        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, current) in counters {
            // Interfaces that just appeared only set a baseline.
            guard let previous = last.counters[name] else { continue }
            received &+= Self.counterDelta(current.rx, previous.rx, plausible: plausible)
            sent &+= Self.counterDelta(current.tx, previous.tx, plausible: plausible)
        }
        return SystemNetworkRate(download: Double(received) / seconds, upload: Double(sent) / seconds)
    }

    /// Upper bound used to tell a counter wrap from a counter reset (well above 10 Gbit/s).
    private static let maxPlausibleBytesPerSecond = 2.5e9

    /// Growth of an interface byte counter between two readings.
    ///
    /// The kernel only hands 64-bit counters to entitled tools such as netstat; other processes get
    /// them truncated to 32 bits (and rounded to 1 KiB), so they wrap every 4 GiB. A smaller reading
    /// is therefore treated as a 32-bit wrap when the implied rate is plausible, otherwise as a reset (0).
    static func counterDelta(_ current: UInt64, _ previous: UInt64, plausible: Double) -> UInt64 {
        if current >= previous { return current - previous }
        let limit = UInt64(UInt32.max)
        guard previous <= limit, current <= limit else { return 0 }
        let wrapped = (limit - previous) + current + 1
        return Double(wrapped) <= plausible ? wrapped : 0
    }

    /// True for physical interfaces worth counting: Ethernet / Wi-Fi / USB / Thunderbolt ("en*").
    /// Tunnels (utun, ipsec), AWDL, low-latency WLAN, bridges, loopback and the like are left out so
    /// VPN traffic isn't counted twice.
    static func isCountedInterface(_ name: String) -> Bool {
        let excluded = ["lo", "utun", "awdl", "llw", "gif", "stf", "anpi", "ap", "bridge", "ipsec", "vmenet", "pdp_ip"]
        guard name.hasPrefix("en") else { return false }
        return !excluded.contains { name.hasPrefix($0) }
    }

    /// Byte counters of the counted interfaces, keyed by interface name.
    static func interfaceCounters() -> [String: (rx: UInt64, tx: UInt64)]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        // Interfaces can appear between the two calls; leave some headroom.
        length += length / 8 + 512
        var buffer = [UInt8](repeating: 0, count: length)
        let status = buffer.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &length, nil, 0) }
        guard status == 0 else { return nil }

        let headerSize = MemoryLayout<if_msghdr2>.size
        let nameLengthOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_nlen) ?? 5
        let nameOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) ?? 8
        var result: [String: (rx: UInt64, tx: UInt64)] = [:]

        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                defer { offset += messageLength }
                guard Int32(header.ifm_type) == RTM_IFINFO2, messageLength >= headerSize else { continue }

                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard message.ifm_flags & IFF_LOOPBACK == 0 else { continue }

                // The interface's link-level sockaddr_dl follows the header and starts with its name.
                var name = ""
                let addressStart = offset + headerSize
                if message.ifm_addrs & RTA_IFP != 0, addressStart + nameOffset <= offset + messageLength {
                    let nameLength = Int(raw[addressStart + nameLengthOffset])
                    let nameEnd = addressStart + nameOffset + nameLength
                    if nameLength > 0, nameEnd <= offset + messageLength {
                        name = String(decoding: raw[(addressStart + nameOffset)..<nameEnd], as: UTF8.self)
                    }
                }
                if name.isEmpty {
                    var chars = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(message.ifm_index), &chars) != nil {
                        name = String(cString: chars)
                    }
                }
                guard isCountedInterface(name) else { continue }
                result[name] = (message.ifm_data.ifi_ibytes, message.ifm_data.ifi_obytes)
            }
        }
        return result
    }

    // MARK: Processes

    /// Forgets per-process CPU baselines and caches (when the System tab goes away).
    func resetProcesses() {
        processRecords.removeAll()
        lastProcessSweep = nil
        pinnedKeys = []
    }

    /// Where one process's figures are added up.
    private enum Placement {
        /// Into an app's row; `isOwn` when the process runs from inside that bundle (it can lead the row).
        case bundle(String, isOwn: Bool)
        case process
        case executable(String)
    }

    /// One sweep over the current user's processes, grouped by app.
    func sampleProcesses() -> SystemProcessSample {
        let sweepTime = mach_absolute_time()
        let previousSweep = lastProcessSweep
        lastProcessSweep = sweepTime
        let wallNanos = previousSweep.map { SystemClock.nanoseconds(fromAbsolute: sweepTime &- $0) } ?? 0
        let hasCPU = previousSweep != nil && wallNanos > 0

        var next: [pid_t: ProcessRecord] = [:]
        struct Accumulator {
            var kind: SystemProcessGroup.Kind
            var name: String
            var pids: [pid_t] = []
            var cpu = 0.0
            var memory: UInt64 = 0
            var leaderPID: pid_t?
            var leaderStartTime: UInt64 = 0
            var leaderPath: String?
            var isSystemPath = true
        }
        var groups: [String: Accumulator] = [:]
        /// Bundles of responsible processes, looked up once per sweep.
        var ownerCache: [pid_t: [String]] = [:]

        for pid in Self.allPIDs() where pid > 0 {
            // Fails fast (EPERM) for other users' processes, so it goes first.
            guard let usage = Self.resourceUsage(pid),
                  let info = Self.shortInfo(pid), info.pbsi_uid == userID, info.pbsi_status != UInt32(SZOMB)
            else { continue }

            let cpuTime = SystemClock.nanoseconds(fromAbsolute: usage.ri_user_time &+ usage.ri_system_time)
            let start = usage.ri_proc_start_abstime
            let command = Self.command(info)
            var record: ProcessRecord
            var cpuDelta: UInt64 = 0
            if let previous = processRecords[pid], previous.startTime == start {
                cpuDelta = cpuTime >= previous.cpuTime ? cpuTime - previous.cpuTime : 0
                if previous.command == command {
                    record = previous
                } else {
                    // Same pid and start time but another program (exec, e.g. a pyenv shim or `sh -c 'exec …'`):
                    // path, name and grouping are read again.
                    record = makeRecord(pid: pid, info: info, command: command, start: start, ownerCache: &ownerCache)
                    record.isPromoted = previous.isPromoted
                }
            } else {
                record = makeRecord(pid: pid, info: info, command: command, start: start, ownerCache: &ownerCache)
                // A process that started since the previous sweep spent all of its CPU time inside the interval.
                if let previousSweep, start > previousSweep { cpuDelta = cpuTime }
            }
            record.cpuTime = cpuTime
            let cpu = hasCPU ? Double(cpuDelta) / Double(wallNanos) * 100 : 0
            let memory = usage.ri_phys_footprint
            let processKey = "pid:\(pid):\(start)"

            let placement: Placement
            if let bundle = groupBundle(record.bundles) {
                placement = .bundle(bundle, isOwn: true)
            } else {
                if record.isPromoted {
                    record.isPromoted = cpu >= Self.looseProcessCPUReleaseThreshold || memory >= Self.looseProcessMemoryReleaseThreshold
                } else {
                    record.isPromoted = cpu > Self.looseProcessCPUThreshold || memory > Self.looseProcessMemoryThreshold
                }
                if pinnedKeys.contains(processKey) {
                    placement = .process
                } else if let owner = groupBundle(record.ownerBundles), record.isAlwaysCredited || !record.isPromoted {
                    placement = .bundle(owner, isOwn: false)
                } else if record.isPromoted {
                    // Heavy on its own (a runaway `yes`, a 2 GB dev server): its own row with its own Quit.
                    placement = .process
                } else {
                    placement = .executable(record.path ?? record.name)
                }
            }
            next[pid] = record

            let key: String
            var group: Accumulator
            switch placement {
            case let .bundle(bundle, isOwn):
                key = bundle
                group = groups[key] ?? Accumulator(kind: .bundle, name: Self.bundleName(bundle))
                // Leader: the oldest main executable of the bundle.
                if isOwn, let path = record.path, Self.isMainExecutable(path, of: bundle),
                   group.leaderPID == nil || start < group.leaderStartTime {
                    group.leaderPID = pid
                    group.leaderStartTime = start
                    group.leaderPath = path
                    group.isSystemPath = record.isSystemPath
                }
            case .process:
                key = processKey
                group = Accumulator(kind: .process, name: record.name)
                group.leaderPID = pid
                group.leaderStartTime = start
                group.leaderPath = record.path
                group.isSystemPath = record.isSystemPath
            case let .executable(executable):
                key = "exe:" + executable
                group = groups[key] ?? Accumulator(kind: .executable, name: record.name)
            }
            group.pids.append(pid)
            group.memory &+= memory
            group.cpu += cpu
            groups[key] = group
        }
        processRecords = next

        var result: [SystemProcessGroup] = []
        result.reserveCapacity(groups.count)
        for (key, group) in groups {
            if group.kind == .executable, !pinnedKeys.contains(key) {
                // Light processes added up only make the list when together they are heavy.
                let heavyCPU = hasCPU && group.cpu > Self.looseProcessCPUThreshold
                guard heavyCPU || group.memory > Self.looseProcessMemoryThreshold else { continue }
            }
            result.append(SystemProcessGroup(
                key: key,
                kind: group.kind,
                bundlePath: group.kind == .bundle ? key : nil,
                name: group.name,
                pids: group.pids.sorted(),
                leaderPID: group.leaderPID,
                leaderStartTime: group.leaderStartTime,
                leaderPath: group.leaderPath,
                cpu: hasCPU ? group.cpu : nil,
                memory: group.memory,
                isSystemPath: group.isSystemPath
            ))
        }
        return SystemProcessSample(groups: result, hasCPU: hasCPU)
    }

    private func makeRecord(
        pid: pid_t, info: proc_bsdshortinfo, command: String, start: UInt64, ownerCache: inout [pid_t: [String]]
    ) -> ProcessRecord {
        let path = Self.executablePath(pid)
        let bundles = path.map(Self.appBundles(in:)) ?? []
        let name: String
        if let bundle = bundles.first {
            name = Self.bundleName(bundle)
        } else if let path {
            name = Self.displayName(forExecutable: (path as NSString).lastPathComponent)
        } else {
            name = command
        }

        var ownerBundles: [String] = []
        if bundles.isEmpty, let responsible = Self.responsiblePID(for: pid), responsible != pid {
            if let cached = ownerCache[responsible] {
                ownerBundles = cached
            } else {
                ownerBundles = Self.executablePath(responsible).map(Self.appBundles(in:)) ?? []
                ownerCache[responsible] = ownerBundles
            }
        }

        let isSystemPath = path.map(Self.isSystemLocation) ?? true
        return ProcessRecord(
            startTime: start, cpuTime: 0, command: command, path: path, bundles: bundles,
            ownerBundles: ownerBundles,
            isAlwaysCredited: isSystemPath || (path?.contains(".xpc/") ?? true),
            name: name.isEmpty ? "pid \(pid)" : name,
            isSystemPath: isSystemPath
        )
    }

    /// The bundle a process is grouped under: the outermost `.app` in its path, or an app nested in it
    /// that runs as a Dock app of its own (Xcode.app/…/Simulator.app). Helpers in the usual helper
    /// folders always count toward the outer app.
    private func groupBundle(_ bundles: [String]) -> String? {
        guard let outermost = bundles.first else { return nil }
        guard bundles.count > 1, !registeredAppBundles.isEmpty else { return outermost }
        for inner in bundles.dropFirst().reversed() where registeredAppBundles.contains(inner) {
            let between = inner.dropFirst(outermost.count)
            if !Self.helperFolders.contains(where: { between.contains($0) }) { return inner }
        }
        return outermost
    }

    private static let helperFolders = [
        "/Contents/Frameworks/", "/Contents/XPCServices/", "/Contents/Library/LoginItems/", "/Contents/PlugIns/",
        "/Contents/Helpers/",
    ]

    /// "/Applications/Google Chrome.app/…/Google Chrome Helper.app/Contents/MacOS/…" → "/Applications/Google Chrome.app".
    static func outermostAppBundle(of path: String) -> String? {
        appBundles(in: path).first
    }

    /// Every `.app` bundle in a path, outermost first.
    static func appBundles(in path: String) -> [String] {
        var bundles: [String] = []
        var searchStart = path.startIndex
        while let range = path.range(of: ".app/", range: searchStart..<path.endIndex) {
            bundles.append(String(path[..<range.lowerBound]) + ".app")
            searchStart = range.upperBound
        }
        return bundles
    }

    /// The executable sits directly in the bundle's Contents/MacOS (not in a nested bundle).
    static func isMainExecutable(_ path: String, of bundle: String) -> Bool {
        guard path.hasPrefix(bundle) else { return false }
        let rest = path.dropFirst(bundle.count)
        return rest.hasPrefix("/Contents/MacOS/") && !rest.contains(".app/")
    }

    /// "/Applications/Xcode.app" → "Xcode".
    static func bundleName(_ bundle: String) -> String {
        let file = (bundle as NSString).lastPathComponent
        return file.hasSuffix(".app") ? String(file.dropLast(4)) : file
    }

    /// Executables in OS-owned locations (daemons, agents, frameworks, cryptexes); these are never
    /// signalled. Command-line tools in /bin and /usr/bin (perl, zsh, yes…) are not included: when one
    /// of the user's own runs away, quitting it is fine.
    static func isSystemLocation(_ path: String) -> Bool {
        let prefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/private/var/", "/usr/standalone/"]
        return prefixes.contains { path.hasPrefix($0) }
    }

    /// Tidies reverse-DNS service names, e.g. "com.apple.WebKit.WebContent" → "WebKit WebContent".
    static func displayName(forExecutable name: String) -> String {
        guard name.hasPrefix("com.apple.") else { return name }
        return name.dropFirst("com.apple.".count).replacingOccurrences(of: ".", with: " ")
    }

    // MARK: Responsible process

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` from libSystem: the process macOS holds responsible
    /// for another (the app behind its XPC services and child tools; what Activity Monitor and privacy
    /// prompts attribute work to). Looked up at run time; nil when the symbol is missing.
    private static let responsibleFunction: ResponsibleFunction? = {
        // RTLD_DEFAULT is ((void *)-2) on Darwin.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let function = responsibleFunction else { return nil }
        let responsible = function(pid)
        return responsible > 0 ? responsible : nil
    }

    // MARK: libproc wrappers

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        // Processes can start between the two calls; leave headroom.
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return Array(pids.prefix(min(Int(count), pids.count)))
    }

    static func shortInfo(_ pid: pid_t) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    static func resourceUsage(_ pid: pid_t) -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage : nil
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The short process name (`pbsi_comm`, at most 16 bytes).
    static func command(_ info: proc_bsdshortinfo) -> String {
        withUnsafeBytes(of: info.pbsi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// True while `pid` still names the same live process (same start time) owned by the current user.
    static func isSameUserProcess(_ pid: pid_t, startTime: UInt64) -> Bool {
        guard pid > 0, let info = shortInfo(pid), info.pbsi_uid == getuid(), info.pbsi_status != UInt32(SZOMB),
              let usage = resourceUsage(pid)
        else { return false }
        return usage.ri_proc_start_abstime == startTime
    }

    /// Checked right before a loose process is signalled: still the same live process of the current
    /// user (start time), still running the executable it was listed with (an exec into another
    /// program fails this), and not in an OS location.
    static func canSignal(_ pid: pid_t, startTime: UInt64, path: String) -> Bool {
        guard isSameUserProcess(pid, startTime: startTime), let current = executablePath(pid) else { return false }
        return current == path && !isSystemLocation(current)
    }
}

// MARK: - Hang detection

/// Detects apps whose main thread stops answering Accessibility requests (what macOS shows as
/// "Not Responding"). Requires Accessibility permission. Use from one serial queue only; the owner
/// runs it at user-initiated QoS so a busy Mac can't stretch an instant failure into a "timeout".
final class SystemHangProbe: @unchecked Sendable {
    /// How long one app may take to answer before the attempt counts as a failure.
    static let messagingTimeout: Float = 0.3
    /// Consecutive failed checks before an app is reported, to ignore momentary stalls.
    static let failuresToReport = 2

    /// A request only counts as timed out when it failed after at least this long. Apps without a
    /// working Accessibility server fail instantly with the same error and are not hung.
    static let minimumTimeoutSeconds = Double(messagingTimeout) * 0.8
    /// A failure faster than this means the app has no working Accessibility server at all; such an
    /// app is never reported (its later replies can't tell a hang from a slow failure).
    static let instantFailureSeconds = 0.1

    /// The outcome of one Accessibility request.
    struct Reply: Sendable {
        var error: AXError
        var seconds: Double
    }

    private var failures: [pid_t: Int] = [:]
    /// Apps that once failed instantly; skipped for as long as they keep running.
    private var unsupported = Set<pid_t>()

    func reset() {
        failures.removeAll()
        unsupported.removeAll()
    }

    /// Asks every app for its AX role concurrently. Returns nil when Accessibility access is missing.
    func check(_ pids: [pid_t]) -> Set<pid_t>? {
        guard AXIsProcessTrusted() else {
            reset()
            return nil
        }
        return evaluate(pids, query: Self.queryRole)
    }

    /// One Accessibility round trip to an app's main thread, timed.
    static func queryRole(_ pid: pid_t) -> Reply {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var value: CFTypeRef?
        let start = SystemClock.now()
        let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return Reply(error: error, seconds: Double(SystemClock.now() &- start) / 1_000_000_000)
    }

    /// Runs `query` for every pid in parallel and updates the consecutive-failure counts. Split from
    /// `check` so the counting can be exercised with canned replies.
    func evaluate(_ pids: [pid_t], query: (pid_t) -> Reply) -> Set<pid_t>? {
        // Forget apps that quit (their pids may be reused later).
        unsupported.formIntersection(pids)
        let probed = pids.filter { !unsupported.contains($0) }
        guard !probed.isEmpty else {
            failures.removeAll()
            return []
        }

        let replies = UnsafeMutableBufferPointer<Reply>.allocate(capacity: probed.count)
        replies.initialize(repeating: Reply(error: .success, seconds: 0))
        defer { replies.deallocate() }

        // A hung app costs the full timeout; querying in parallel keeps a sweep well under a second.
        DispatchQueue.concurrentPerform(iterations: probed.count) { index in
            replies[index] = query(probed[index])
        }

        var next: [pid_t: Int] = [:]
        var unresponsive = Set<pid_t>()
        for (index, pid) in probed.enumerated() {
            let reply = replies[index]
            if reply.error == .apiDisabled {
                reset()
                return nil
            }
            guard reply.error == .cannotComplete else { continue }
            if reply.seconds < Self.instantFailureSeconds {
                unsupported.insert(pid)
                continue
            }
            guard reply.seconds >= Self.minimumTimeoutSeconds else { continue }
            let count = (failures[pid] ?? 0) + 1
            next[pid] = count
            if count >= Self.failuresToReport { unresponsive.insert(pid) }
        }
        failures = next
        return unresponsive
    }
}
