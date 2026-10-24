import Darwin
import Foundation

// Native discovery of listening TCP ports for the Dev Ports module, through libproc (no lsof).
// Everything in this file runs on the store's serial scan queue, never on the main thread.
// Processes start and exit between calls, so every failing syscall just skips that process or socket.

// MARK: - Values

/// Which local addresses a listening socket accepts connections on.
enum DevPortBinding: Int, Comparable, Sendable {
    /// 127.0.0.1 / ::1: reachable from this Mac only.
    case loopback
    /// One interface address, e.g. 192.168.1.20.
    case specificAddress
    /// 0.0.0.0 / ::: reachable from the local network too ("LAN").
    case allInterfaces

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A process as it was when scanned. Signals are only sent after re-checking that `pid` still names
/// this exact process (same start time and command, same owner), so a reused pid is never hit.
struct DevPortProcess: Hashable, Sendable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    /// Kernel command name (at most 16 characters), e.g. "node" or "httpd".
    let command: String

    var startDate: Date {
        Date(timeIntervalSince1970: TimeInterval(startSeconds) + TimeInterval(startMicroseconds) / 1_000_000)
    }
}

/// Why Crest won't stop a listener itself.
enum DevPortProtection: Equatable, Sendable {
    case none
    /// The managing (master) process belongs to root or another user, e.g. Valet's nginx.
    case otherUser
    /// A macOS agent or daemon.
    case system
    /// A regular app: quitting it is the way to close its port.
    case app(name: String)
    /// A container runtime forwarding a container's port; stopping it would stop every container.
    case containerRuntime(name: String)
}

/// How interesting a listener is to a developer.
enum DevPortCategory: Int, Sendable {
    /// A known dev server, database or runtime executable (node, php, httpd, mysqld…).
    case devServer
    /// An unknown executable on a non-ephemeral port that isn't an app, agent or system service,
    /// e.g. a Go or Rust binary built in a project folder.
    case likelyDev
    /// Everything else (AirPlay receiver, Spotify, editor helpers on random ports…); only shown with "Show all".
    case other
}

/// One row: a port and the server holding it. Every socket of that server on the port (IPv4 + IPv6,
/// prefork workers…) is collapsed here; an unrelated process on the same port gets its own row.
struct DevPortEntry: Identifiable, Equatable, Sendable {
    /// Two servers can share a port (one on 127.0.0.1, another on ::1; Docker's forwarder on * beside a
    /// native postgres on 127.0.0.1), so rows are told apart by port and owner.
    struct ID: Hashable, Sendable {
        let port: UInt16
        /// The master's pid, or the pid of the root-owned master above the listeners (Valet's nginx).
        let owner: pid_t
    }

    let id: ID
    var port: UInt16 { id.port }
    /// The widest binding among the server's sockets on the port.
    let binding: DevPortBinding
    /// The bound address when `binding` is `.specificAddress`.
    let boundAddress: String?
    /// Process name for display, e.g. "node", "httpd", "python".
    let processName: String
    /// Project folder (from the working directory) or the install it comes from ("MAMP", "Homebrew"…).
    let context: String?
    /// Friendly service name when it says more than the process name, e.g. "Vite" or "MySQL X"
    /// (never "MySQL" beside mysqld).
    let serviceLabel: String?
    /// The server's working directory when it is a project folder.
    let projectPath: String?
    let executablePath: String?
    let category: DevPortCategory
    /// Whether opening it in a browser makes sense: a dev listener that isn't a database, FastCGI, debugger…
    let isHTTP: Bool
    /// What Stop signals: the topmost same-command ancestor that belongs to this server (see the scanner).
    let master: DevPortProcess
    /// Every process of this server holding a listening socket on the port.
    let listeners: [DevPortProcess]
    let protection: DevPortProtection
    /// The master has no controlling terminal: launchd, a service manager, a supervisor or an app
    /// started it, so it may come back by itself after Stop.
    let isDetached: Bool

    var isDev: Bool { category != .other }
    var isStoppable: Bool { protection == .none }
    var isLAN: Bool { binding == .allInterfaces }

    /// Counted by the closed-notch indicator: web dev servers the user started. Databases and
    /// root-run infrastructure (Valet's nginx is up from boot to shutdown) would keep it lit forever.
    var countsForIndicator: Bool { isDev && isHTTP && protection != .otherUser }

    /// Processes to signal on Stop/Kill: the master first, then any listener it doesn't cover.
    var signalTargets: [DevPortProcess] {
        [master] + listeners.filter { $0 != master }
    }

    private var scheme: String { port == 443 || port == 8443 ? "https" : "http" }

    private func urlString(host: String) -> String {
        let defaultPort: UInt16 = scheme == "https" ? 443 : 80
        return port == defaultPort ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }

    /// Browser URL, e.g. "http://localhost:5173" or "https://localhost"; nil for non-HTTP services.
    var browserURL: URL? {
        guard isHTTP else { return nil }
        let host = binding == .specificAddress ? (boundAddress.map(Self.hostLiteral) ?? "localhost") : "localhost"
        return URL(string: urlString(host: host))
    }

    /// What Copy puts on the pasteboard: the browser URL, or "localhost:<port>" for other services.
    var copyText: String {
        browserURL?.absoluteString ?? "localhost:\(port)"
    }

    /// Address for other devices on the network, e.g. "http://192.168.1.20:8888" (or "192.168.1.20:8889").
    func lanText(address: String) -> String {
        isHTTP ? urlString(host: address) : "\(address):\(port)"
    }

    /// Wraps IPv6 literals in brackets for URLs.
    private static func hostLiteral(_ address: String) -> String {
        address.contains(":") ? "[\(address)]" : address
    }
}

/// Result of one scan.
struct DevPortsScanResult: Sendable {
    /// Rows sorted dev servers first, stoppable ones before the rest, web servers before databases, then by port.
    /// A quick scan only holds dev executables (and tracked likely-dev servers).
    let entries: [DevPortEntry]
    /// True for a scan over all of the user's processes.
    let isFull: Bool
    /// Primary IPv4 address of Wi-Fi/Ethernet (en0, then en1…); only looked up by full scans.
    let lanAddress: String?
    /// Thread CPU time the scan took, in seconds.
    let cpuTime: TimeInterval
    /// Wall-clock time the scan took, in seconds.
    let wallTime: TimeInterval
}

// MARK: - Scanner

/// Finds the current user's listening TCP sockets. Not thread-safe: use from one serial queue only.
///
/// A full scan lists the file descriptors of every process the user owns; a quick scan (for the
/// closed-notch indicator) only those of dev executables plus the likely-dev servers found by the
/// last full scan. Root's processes can't be inspected without admin rights.
final class DevPortsScanner: @unchecked Sendable {
    private let userID = getuid()
    private let ownPID = getpid()
    private let home = NSHomeDirectory()
    private lazy var hasValet = FileManager.default.fileExists(atPath: home + "/.config/valet")

    /// Reused buffer for PROC_PIDLISTFDS; grows to the largest descriptor table seen.
    private var fdBuffer = [proc_fdinfo](repeating: proc_fdinfo(), count: 512)
    private static let maxFDBuffer = 1 << 16
    private var socketInfo = socket_fdinfo()

    /// Executable path and working directory per process; pruned after every scan.
    private var details: [DevPortProcess: Details] = [:]
    /// Likely-dev listeners from the last full scan, by pid; quick scans inspect these too.
    private var tracked: [pid_t: DevPortProcess] = [:]
    /// Ancestors seen running servers on different ports (process managers), with their start time.
    /// Remembered so that while one of their apps restarts, the manager isn't taken for the other
    /// app's reloader and signalled by its Stop.
    private var managers: [pid_t: (seconds: UInt64, microseconds: UInt64)] = [:]

    private struct Details {
        var path: String?
        var cwd: String?
    }

    private struct SocketHit {
        var port: UInt16
        var binding: DevPortBinding
        var address: String?
    }

    private struct Listener {
        var process: DevPortProcess
        var name: String
        var parentPID: pid_t
        var hasTerminal: Bool
        /// Same-command ancestors, nearest first (see `sameCommandAncestors`).
        var ancestors: [pid_t]
        /// A same-named parent of the topmost ancestor that belongs to someone else (root).
        var foreignParent: pid_t?
        var sockets: [SocketHit]
        var ports: Set<UInt16>
    }

    /// Sockets of one server on one port.
    private struct Group {
        var binding: DevPortBinding
        var address: String?
        var master: pid_t
        /// The listeners' master belongs to root or another user.
        var isForeign: Bool
        var pids: [pid_t]
    }

    private struct MasterInfo {
        var process: DevPortProcess
        var parent: pid_t
        var hasTerminal: Bool
    }

    // MARK: Scan

    func scan(full: Bool) -> DevPortsScanResult {
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)

        var listeners: [pid_t: Listener] = [:]
        for pid in Self.allPIDs() where pid > 1 && pid != ownPID {
            guard let short = Self.shortInfo(pid), short.pbsi_uid == userID, short.pbsi_status != UInt32(SZOMB) else { continue }
            let command = Self.string(short.pbsi_comm)
            if !full {
                guard DevPortsCatalog.isDevCommand(command) || tracked[pid] != nil else { continue }
            }
            let hits = listeningSockets(of: pid)
            guard !hits.isEmpty, let info = Self.bsdInfo(pid), info.pbi_uid == userID else { continue }

            let process = Self.process(pid: pid, info: info)
            let ancestry = sameCommandAncestors(of: pid, parent: pid_t(info.pbi_ppid), command: process.command)
            listeners[pid] = Listener(
                process: process,
                name: Self.string(info.pbi_name),
                parentPID: pid_t(info.pbi_ppid),
                hasTerminal: Self.hasTerminal(info),
                ancestors: ancestry.pids,
                foreignParent: ancestry.foreignParent,
                sockets: hits,
                ports: Set(hits.map(\.port))
            )
        }

        // Listeners below each same-command ancestor, to tell one server's reloader from a process manager.
        var below: [pid_t: [pid_t]] = [:]
        for listener in listeners.values {
            for ancestor in listener.ancestors { below[ancestor, default: []].append(listener.process.pid) }
        }

        // One group per port and master: unrelated servers on the same port stay apart.
        var groups: [DevPortEntry.ID: Group] = [:]
        for listener in listeners.values {
            let master = masterPID(of: listener, listeners: listeners, below: below)
            // Root's master only matters when the walk went all the way up to it.
            let foreign = master == (listener.ancestors.last ?? listener.process.pid) ? listener.foreignParent : nil
            for hit in listener.sockets {
                let key = DevPortEntry.ID(port: hit.port, owner: foreign ?? master)
                var group = groups[key] ?? Group(binding: hit.binding, address: hit.address, master: master, isForeign: foreign != nil, pids: [])
                if hit.binding > group.binding { group.binding = hit.binding; group.address = hit.address }
                if !group.pids.contains(listener.process.pid) { group.pids.append(listener.process.pid) }
                groups[key] = group
            }
        }

        var used = Set<DevPortProcess>()
        var masters: [pid_t: MasterInfo] = [:]
        var entries: [DevPortEntry] = []
        entries.reserveCapacity(groups.count)

        for (key, group) in groups {
            let members = group.pids.compactMap { listeners[$0] }.sorted { $0.process.pid < $1.process.pid }
            guard let lowest = members.first else { continue }
            let primary = group.isForeign ? lowest : (members.first { $0.process.pid == group.master } ?? lowest)
            let port = key.port

            // The master, when it isn't a listener itself (it may have exited since the walk).
            var master = MasterInfo(process: primary.process, parent: primary.parentPID, hasTerminal: primary.hasTerminal)
            if !group.isForeign && group.master != primary.process.pid {
                if let known = masters[group.master] {
                    master = known
                } else if let info = Self.bsdInfo(group.master), info.pbi_uid == userID {
                    master = MasterInfo(process: Self.process(pid: group.master, info: info), parent: pid_t(info.pbi_ppid), hasTerminal: Self.hasTerminal(info))
                    masters[group.master] = master
                }
            }

            let listenerDetails = details(for: primary.process)
            let masterDetails = master.process == primary.process ? listenerDetails : details(for: master.process)
            used.insert(primary.process)
            used.insert(master.process)

            let command = primary.process.command
            let path = listenerDetails.path

            // The master's folder first: `php artisan serve` runs in the project, its `php -S` child in public/.
            let masterProject = DevPortsCatalog.projectFolder(workingDirectory: masterDetails.cwd, home: home)
            let listenerProject = DevPortsCatalog.projectFolder(workingDirectory: listenerDetails.cwd, home: home)
            let project = masterProject ?? listenerProject
            let projectPath = masterProject != nil ? masterDetails.cwd : (listenerProject != nil ? listenerDetails.cwd : nil)
            let context = project ?? DevPortsCatalog.stackName(path: path, command: command, hasValet: hasValet)

            let category: DevPortCategory
            if port >= DevPortsCatalog.ephemeralPortStart {
                category = .other
            } else if DevPortsCatalog.isDevServer(command: command, path: path, inProject: project != nil) {
                category = .devServer
            } else if DevPortsCatalog.isBackgroundListener(command: command, path: path, home: home) {
                category = .other
            } else {
                category = .likelyDev
            }

            let protection: DevPortProtection
            if group.isForeign {
                protection = .otherUser
            } else {
                let masterProtection = DevPortsCatalog.protection(
                    command: master.process.command, path: masterDetails.path, parentPID: master.parent, inProject: masterProject != nil
                )
                let listenerProtection = DevPortsCatalog.protection(
                    command: command, path: path, parentPID: primary.parentPID, inProject: listenerProject != nil
                )
                protection = masterProtection != .none ? masterProtection : listenerProtection
            }

            // Port-based guesses ("5000 → Flask") would mislabel AirPlay and friends.
            let label = category == .other ? nil : DevPortsCatalog.serviceLabel(command: command, port: port)

            entries.append(DevPortEntry(
                id: key,
                binding: group.binding,
                boundAddress: group.binding == .specificAddress ? group.address : nil,
                processName: DevPortsCatalog.displayName(command: command, fullName: primary.name),
                context: context,
                serviceLabel: label.flatMap { DevPortsCatalog.labelAddsInformation($0, command: command) ? $0 : nil },
                projectPath: Self.trimmedPath(projectPath),
                executablePath: path,
                category: category,
                isHTTP: category != .other && DevPortsCatalog.isLikelyHTTP(command: command, port: port),
                master: master.process,
                listeners: members.map(\.process),
                protection: protection,
                isDetached: !master.hasTerminal
            ))
        }

        // Dev servers first; among them the ones the user can act on (not root's or Docker's), web
        // servers before databases, then by port.
        entries.sort { lhs, rhs in
            if lhs.isDev != rhs.isDev { return lhs.isDev }
            if lhs.isStoppable != rhs.isStoppable { return lhs.isStoppable }
            if lhs.isHTTP != rhs.isHTTP { return lhs.isHTTP }
            if lhs.port != rhs.port { return lhs.port < rhs.port }
            return lhs.id.owner < rhs.id.owner
        }

        details = details.filter { used.contains($0.key) }
        if full {
            for pid in Array(managers.keys) where !isKnownManager(pid) { managers[pid] = nil }
            var next: [pid_t: DevPortProcess] = [:]
            for entry in entries where entry.category == .likelyDev {
                for process in entry.listeners { next[process.pid] = process }
            }
            tracked = next
        }

        let lan = full ? Self.primaryIPv4Address() : nil
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpuStart
        let wall = DispatchTime.now().uptimeNanoseconds &- wallStart
        return DevPortsScanResult(
            entries: entries,
            isFull: full,
            lanAddress: lan,
            cpuTime: TimeInterval(cpu) / 1_000_000_000,
            wallTime: TimeInterval(wall) / 1_000_000_000
        )
    }

    /// The process Stop signals for `listener`: the highest same-command ancestor that is still part of
    /// the same server. An ancestor holding sockets itself (prefork master, a reloader that binds first)
    /// qualifies when it holds every port the listener serves; one serving other ports (Jupyter above
    /// its kernels) doesn't. An ancestor without sockets (Django's or uvicorn's reloader, `next dev`)
    /// qualifies only while everything listening below it shares a port with the listener: a process
    /// manager running apps on different ports (pm2, honcho, a hand-rolled supervisor) isn't one server,
    /// and stopping one app must not take the others down.
    private func masterPID(of listener: Listener, listeners: [pid_t: Listener], below: [pid_t: [pid_t]]) -> pid_t {
        var master = listener.process.pid
        for ancestor in listener.ancestors {
            if let own = listeners[ancestor] {
                guard listener.ports.isSubset(of: own.ports) else { break }
            } else {
                guard !isKnownManager(ancestor) else { break }
                let isOneServer = (below[ancestor] ?? []).allSatisfy { pid in
                    listeners[pid].map { !$0.ports.isDisjoint(with: listener.ports) } ?? true
                }
                guard isOneServer else {
                    if let info = Self.bsdInfo(ancestor) { managers[ancestor] = (info.pbi_start_tvsec, info.pbi_start_tvusec) }
                    break
                }
            }
            master = ancestor
        }
        return master
    }

    /// Whether `pid` is still the process manager recorded earlier (not a reused pid).
    private func isKnownManager(_ pid: pid_t) -> Bool {
        guard let start = managers[pid] else { return false }
        guard let info = Self.bsdInfo(pid), info.pbi_start_tvsec == start.seconds, info.pbi_start_tvusec == start.microseconds else {
            managers[pid] = nil
            return false
        }
        return true
    }

    /// Ancestors of `pid`, nearest first, while each runs the same command from the same executable
    /// (prefork masters, reloaders, cluster primaries, watchers, process managers). Stops at launchd,
    /// at a different program, or at a parent owned by someone else, reported as `foreignParent`
    /// since that master is out of reach.
    private func sameCommandAncestors(of pid: pid_t, parent firstParent: pid_t, command: String) -> (pids: [pid_t], foreignParent: pid_t?) {
        var chain: [pid_t] = []
        var current = pid
        var parent = firstParent
        var currentPath = Self.executablePath(pid)
        for _ in 0..<32 {
            guard parent > 1, parent != current, let parentInfo = Self.shortInfo(parent),
                  Self.string(parentInfo.pbsi_comm) == command
            else { break }
            if parentInfo.pbsi_uid != userID { return (chain, parent) }
            let parentPath = Self.executablePath(parent)
            guard parentPath != nil, parentPath == currentPath else { break }
            chain.append(parent)
            current = parent
            currentPath = parentPath
            parent = pid_t(parentInfo.pbsi_ppid)
        }
        return (chain, nil)
    }

    private func details(for process: DevPortProcess) -> Details {
        if let cached = details[process] { return cached }
        let value = Details(path: Self.executablePath(process.pid), cwd: Self.workingDirectory(process.pid))
        details[process] = value
        return value
    }

    // MARK: Sockets

    /// TCP sockets of `pid` in the LISTEN state.
    private func listeningSockets(of pid: pid_t) -> [SocketHit] {
        let entrySize = MemoryLayout<proc_fdinfo>.stride
        var count = 0
        while true {
            let bytes = fdBuffer.withUnsafeMutableBytes { raw in
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
            }
            guard bytes > 0 else { return [] }
            count = Int(bytes) / entrySize
            // A full buffer may have been truncated: grow it and ask again.
            guard count >= fdBuffer.count, fdBuffer.count < Self.maxFDBuffer else { break }
            fdBuffer = [proc_fdinfo](repeating: proc_fdinfo(), count: min(fdBuffer.count * 4, Self.maxFDBuffer))
        }

        var hits: [SocketHit] = []
        let socketSize = Int32(MemoryLayout<socket_fdinfo>.size)
        let socketType = UInt32(PROX_FDTYPE_SOCKET)
        for index in 0..<min(count, fdBuffer.count) {
            let descriptor = fdBuffer[index]
            guard descriptor.proc_fdtype == socketType,
                  proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo, socketSize) == socketSize
            else { continue }

            let socket = socketInfo.psi
            guard socket.soi_kind == Int32(SOCKINFO_TCP),
                  socket.soi_family == AF_INET || socket.soi_family == AF_INET6,
                  socket.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
            else { continue }

            let inet = socket.soi_proto.pri_tcp.tcpsi_ini
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport))
            guard port != 0 else { continue }
            // An IPv6 socket bound to an IPv4 address (the JVM's default, or `bind(("::ffff:127.0.0.1", …))`)
            // is flagged IPv4-only and keeps the address in the IPv4 slot, as lsof reads it.
            let vflag = inet.insi_vflag
            let isIPv4 = socket.soi_family == AF_INET
                || (vflag & UInt8(INI_IPV4) != 0 && vflag & UInt8(INI_IPV6) == 0)
            let (binding, address) = isIPv4
                ? Self.classify(ipv4: inet.insi_laddr.ina_46.i46a_addr4)
                : Self.classify(ipv6: inet.insi_laddr.ina_6)
            hits.append(SocketHit(port: port, binding: binding, address: address))
        }
        return hits
    }

    private static func classify(ipv4 address: in_addr) -> (DevPortBinding, String?) {
        let value = UInt32(bigEndian: address.s_addr)
        if value == 0 { return (.allInterfaces, nil) }
        if value >> 24 == 127 { return (.loopback, nil) }
        var copy = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &copy, &buffer, socklen_t(buffer.count)) != nil else { return (.specificAddress, nil) }
        return (.specificAddress, String(cString: buffer))
    }

    private static func classify(ipv6 address: in6_addr) -> (DevPortBinding, String?) {
        enum Kind { case any, loopback, ipv4(in_addr) }
        let kind: Kind? = withUnsafeBytes(of: address) { raw in
            if raw.allSatisfy({ $0 == 0 }) { return .any }
            if raw.prefix(15).allSatisfy({ $0 == 0 }) && raw[15] == 1 { return .loopback }
            // IPv4-mapped (::ffff:a.b.c.d) or the kernel's IPv4-in-IPv6 form (12 zero bytes, then a.b.c.d).
            let isMapped = raw.prefix(10).allSatisfy({ $0 == 0 }) && raw[10] == 0xff && raw[11] == 0xff
            guard isMapped || raw.prefix(12).allSatisfy({ $0 == 0 }) else { return nil }
            var ipv4 = in_addr()
            withUnsafeMutableBytes(of: &ipv4.s_addr) { $0.copyBytes(from: raw[12..<16]) }
            return .ipv4(ipv4)
        }
        switch kind {
        case .any: return (.allInterfaces, nil)
        case .loopback: return (.loopback, nil)
        case .ipv4(let ipv4): return classify(ipv4: ipv4)
        case nil: break
        }
        var copy = address
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &copy, &buffer, socklen_t(buffer.count)) != nil else { return (.specificAddress, nil) }
        return (.specificAddress, String(cString: buffer))
    }

    // MARK: Network address

    /// First IPv4 address of en0, then en1, then any other "en" interface that is up.
    static func primaryIPv4Address() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var found: [String: String] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(truncatingIfNeeded: current.pointee.ifa_flags)
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("en"), found[name] == nil else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            // Self-assigned (169.254.x.x) addresses aren't reachable by other devices.
            guard !text.hasPrefix("169.254.") else { continue }
            found[name] = text
        }
        if let primary = found["en0"] ?? found["en1"] { return primary }
        return found.sorted { $0.key < $1.key }.first?.value
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

    /// Owner, parent and command of any process (works for other users' processes too).
    static func shortInfo(_ pid: pid_t) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// Full BSD info including start time and the 32-character name; only for the user's own processes.
    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// Whether the process has a controlling terminal (started from a shell in Terminal, an IDE console…).
    static func hasTerminal(_ info: proc_bsdinfo) -> Bool {
        info.e_tdev != UInt32.max && info.e_tdev != 0
    }

    static func process(pid: pid_t, info: proc_bsdinfo) -> DevPortProcess {
        DevPortProcess(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec,
            command: string(info.pbi_comm)
        )
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = string(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// Decodes a fixed-size, NUL-padded C character array (imported as a tuple).
    static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func trimmedPath(_ path: String?) -> String? {
        guard var path else { return nil }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

// MARK: - Signals

/// Outcome of signalling a listener's processes.
enum DevPortSignalOutcome: Sendable {
    /// At least one process received the signal.
    case sent
    /// None of the processes exist any more (or their pids now belong to other processes).
    case gone
    /// The kernel refused (EPERM), or a process failed the safety checks.
    case notPermitted
}

enum DevPortsSignaller {
    /// Sends `signal` to every target that still is the exact process that was scanned.
    static func send(_ signal: Int32, to targets: [DevPortProcess]) -> DevPortSignalOutcome {
        var sent = false
        var refused = false
        for target in targets {
            switch validate(target) {
            case .gone:
                continue
            case .unsafe:
                refused = true
                continue
            case .ok:
                break
            }
            if kill(target.pid, signal) == 0 {
                sent = true
            } else if errno != ESRCH {
                refused = true
            }
        }
        if sent { return .sent }
        return refused ? .notPermitted : .gone
    }

    /// The targets that are still running and may be signalled (zombies count as exited). One that now
    /// fails the safety checks is left out: Kill couldn't touch it anyway.
    static func survivors(of targets: [DevPortProcess]) -> [DevPortProcess] {
        targets.filter { validate($0) == .ok }
    }

    private enum Validation { case ok, gone, unsafe }

    /// Re-reads the process right before signalling: same start time and command (pid reuse),
    /// owned by the current user, not Crest, launchd or a protected macOS process.
    private static func validate(_ target: DevPortProcess) -> Validation {
        guard target.pid > 1 else { return .unsafe }
        // Exited (ESRCH), or the pid now belongs to another user's process (EPERM): either way ours is gone.
        guard let info = DevPortsScanner.bsdInfo(target.pid) else { return .gone }
        guard info.pbi_start_tvsec == target.startSeconds,
              info.pbi_start_tvusec == target.startMicroseconds,
              DevPortsScanner.string(info.pbi_comm) == target.command,
              info.pbi_status != UInt32(SZOMB)
        else { return .gone }
        guard target.pid != getpid(), info.pbi_uid == getuid(), info.pbi_ruid == getuid() else { return .unsafe }
        // A worker whose same-named parent belongs to root (Valet's nginx) would just be respawned.
        let parent = pid_t(info.pbi_ppid)
        if parent > 1, let parentInfo = DevPortsScanner.shortInfo(parent),
           parentInfo.pbsi_uid != getuid(), DevPortsScanner.string(parentInfo.pbsi_comm) == target.command {
            return .unsafe
        }
        let path = DevPortsScanner.executablePath(target.pid)
        let inProject = DevPortsCatalog.projectFolder(workingDirectory: DevPortsScanner.workingDirectory(target.pid), home: NSHomeDirectory()) != nil
        let protection = DevPortsCatalog.protection(command: target.command, path: path, parentPID: parent, inProject: inProject)
        return protection == .none ? .ok : .unsafe
    }
}
