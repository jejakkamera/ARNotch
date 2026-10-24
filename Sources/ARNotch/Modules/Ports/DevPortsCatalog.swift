import Foundation

/// Knowledge about dev tooling used to classify, label and protect listeners. Pure functions only,
/// safe to call from any thread. Names are kernel command names (`p_comm`, at most 16 characters,
/// so longer executable names arrive truncated).
enum DevPortsCatalog {
    /// Ports from here up are the IANA dynamic range. Editors, apps and helpers bind random loopback
    /// ports there; dev servers practically never do, so they never count as dev servers.
    static let ephemeralPortStart: UInt16 = 49152

    // MARK: Dev executables

    /// Executables that are dev servers, databases or runtimes, matched case-insensitively.
    private static let devCommands: Set<String> = [
        // JavaScript & friends
        "node", "nodejs", "bun", "deno", "workerd", "esbuild",
        // PHP
        "php", "php-fpm", "php-cgi", "frankenphp", "rr", "symfony", "valet", "herd",
        // Python
        "python", "python3", "python3-intel64", "uvicorn", "gunicorn", "hypercorn", "daphne", "granian", "flask", "streamlit", "jupyter", "jupyter-lab",
        // Ruby, JVM, .NET, Erlang/Elixir, Dart, Go tooling
        "ruby", "rails", "puma", "unicorn", "thin", "falcon",
        "java", "jwebserver", "dotnet", "beam.smp", "dart", "air", "gin",
        // Web servers & proxies
        "httpd", "apache2", "nginx", "caddy", "traefik", "openresty",
        // Databases, caches, queues, search
        "mysqld", "mariadbd", "postgres", "postmaster", "redis-server", "redis-sentinel", "valkey-server", "keydb-server",
        "mongod", "mongos", "memcached", "elasticsearch", "opensearch", "meilisearch", "typesense-server",
        "clickhouse", "clickhouse-server", "influxd", "nats-server", "minio", "pocketbase", "surreal", "cockroach",
        // Static site generators, mail catchers, local AI
        "hugo", "zola", "jekyll", "mailpit", "mailhog", "ollama",
        // Container port forwarders
        "com.docker.backend", "com.docker.vpnkit", "docker-proxy", "vpnkit", "gvproxy",
    ]

    /// Families whose executables carry a version: "python3.12", "php8.3", "php83-fpm", "ruby3.3", "node20".
    private static let versionedFamilies = [
        "python", "php-fpm", "php-cgi", "php", "ruby", "node", "java", "postgres", "mysqld", "mariadbd", "redis-server", "mongod",
    ]

    /// True when `command` names a dev server, database or language runtime.
    static func isDevCommand(_ command: String) -> Bool {
        let name = command.lowercased()
        if devCommands.contains(name) { return true }
        if versionedFamilies.contains(where: { isVersioned(name, of: $0) }) { return true }
        // p_comm keeps only 16 characters ("com.docker.backend" arrives as "com.docker.backe").
        if name.utf8.count >= 15 {
            return devCommands.contains { $0.count > name.count && $0.hasPrefix(name) }
        }
        return false
    }

    /// `name` is `family` plus a version ("php8.3", "node-20"), and for PHP an "-fpm"/"-cgi" tail ("php83-fpm").
    /// A bare prefix is not enough: "phpstorm", "rubymine" and "javaapplauncher" are not runtimes.
    private static func isVersioned(_ name: String, of family: String) -> Bool {
        guard name.hasPrefix(family) else { return false }
        let suffix = name.dropFirst(family.count)
        let tail = suffix.drop { $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-") }
        if tail.isEmpty { return suffix.contains { $0.isNumber } }
        return family == "php" && (tail == "fpm" || tail == "cgi")
    }

    // MARK: Dev tools shipped as apps

    /// Apps that are themselves dev tools, so the runtimes inside them serve the user's projects:
    /// framework Python (Homebrew's and python.org's run from Python.app), Xcode's toolchain,
    /// Postgres.app, Herd, Ollama, DBngin, Local, MAMP, ServBay, FlyEnv, and the container runtimes.
    private static let devToolApps = [
        "python", "xcode", "postgres", "herd", "ollama", "dbngin", "local", "mamp", "mamp pro", "servbay",
        "flyenv", "phpwebstudy", "docker", "orbstack", "podman desktop", "rancher desktop",
    ]

    /// The app a dev executable ships inside when that app isn't a dev tool, e.g. a `node` helper at
    /// "/Applications/Foo.app/Contents/Resources/node" → "Foo". Nil outside app bundles.
    static func hostingApp(path: String?) -> String? {
        guard let path, let bundle = outermostAppName(path) else { return nil }
        let name = bundle.lowercased()
        let isDevTool = devToolApps.contains { tool in
            // "Xcode-beta", "Xcode 26", "Python 3.13" count; "Localizer" doesn't.
            name == tool || (name.hasPrefix(tool) && !(name.dropFirst(tool.count).first?.isLetter ?? false))
        }
        return isDevTool ? nil : bundle
    }

    /// Whether a listener counts as a dev server: a dev executable that isn't a runtime some app ships
    /// for itself. A bundled runtime started in a project folder (say a Spring Boot app run on an IDE's
    /// bundled JDK) is the user's server after all.
    static func isDevServer(command: String, path: String?, inProject: Bool) -> Bool {
        isDevCommand(command) && (inProject || hostingApp(path: path) == nil)
    }

    // MARK: Noise

    /// Apps, agents and helpers that open ports nobody asked for (AirPlay receiver, Spotify Connect,
    /// device managers, editor and browser helpers…). Prefixes, matched case-insensitively.
    private static let backgroundCommandPrefixes = [
        "controlce", "rapportd", "sharingd", "airplay", "identityservicesd", "remoted", "spotify",
        "logioptions", "logiplugin", "logi", "notion", "electron", "google chrome", "chrome", "microsoft",
        "brave", "arc", "safari", "firefox", "figma", "adobe", "creative cloud", "dropbox", "onedrive",
        "slack", "discord", "zoom", "teams", "steam", "raycast", "1password", "termius", "antigravity",
        "language_", "code helper", "cursor", "devsense", "intelliphp", "copilot", "synergy", "tailscale",
    ]

    /// Executable locations owned by macOS.
    static func isSystemLocation(_ path: String) -> Bool {
        let prefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/bin/", "/usr/bin/", "/Library/Apple/", "/private/var/db/", "/Library/Developer/PrivateFrameworks/"]
        return prefixes.contains { path.hasPrefix($0) }
    }

    /// True for listeners that belong to apps, agents and helpers rather than something the user runs
    /// for development. Only consulted for executables that aren't dev commands.
    static func isBackgroundListener(command: String, path: String?, home: String) -> Bool {
        let name = command.lowercased()
        if backgroundCommandPrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        // Unknown location (the process may be exiting): don't promote it.
        guard let path else { return true }
        if isSystemLocation(path) { return true }
        // GUI apps and their helpers, third-party daemons and per-user agents, editor extension servers.
        if path.contains(".app/") || path.hasPrefix("/Library/") || path.hasPrefix(home + "/Library/") { return true }
        if path.contains("/extensions/") { return true }
        return false
    }

    // MARK: Protection

    /// Processes that must never be signalled, whatever their owner or location.
    private static let protectedCommands: Set<String> = [
        "launchd", "kernel_task", "windowserver", "loginwindow", "dock", "finder", "systemuiserver",
        "controlcenter", "rapportd", "sharingd", "coreaudiod", "cfprefsd", "notificationcenter",
    ]

    /// Container runtimes whose port forwarders would take every container down if stopped.
    static func containerRuntime(command: String, path: String?) -> String? {
        let name = command.lowercased()
        let location = path ?? ""
        if name.hasPrefix("com.docker") || name == "vpnkit" || name == "docker-proxy" || location.contains("/Docker.app/") {
            return "Docker"
        }
        if location.contains("/OrbStack.app/") || name.hasPrefix("orbstack") { return "OrbStack" }
        if name == "gvproxy" || name.hasPrefix("podman") { return "Podman" }
        if name == "limactl" || name.hasPrefix("colima") || name.hasPrefix("qemu-system") { return "Colima" }
        return nil
    }

    /// Why Crest refuses to signal `command`, or `.none` when stopping it is fine.
    /// `parentPID` 1 means launchd started it (agents and daemons do; so do apps and MAMP).
    /// `inProject` is true when the process runs in a project folder (see `projectFolder`).
    static func protection(command: String, path: String?, parentPID: pid_t, inProject: Bool) -> DevPortProtection {
        let name = command.lowercased()
        if protectedCommands.contains(name) { return .system }
        if let runtime = containerRuntime(command: command, path: path) { return .containerRuntime(name: runtime) }
        guard let path else { return .system }
        if isSystemLocation(path) && (parentPID == 1 || !isDevCommand(command)) { return .system }
        if let bundle = outermostAppName(path), !isDevServer(command: command, path: path, inProject: inProject) {
            return .app(name: bundle)
        }
        return .none
    }

    /// "/Applications/Spotify.app/Contents/MacOS/Spotify" → "Spotify".
    static func outermostAppName(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        let bundle = path[..<range.lowerBound]
        guard let slash = bundle.lastIndex(of: "/") else { return String(bundle) }
        return String(bundle[bundle.index(after: slash)...])
    }

    // MARK: Labels

    /// Short process name for rows, e.g. "Python" → "python", "com.docker.backe" → "docker".
    static func displayName(command: String, fullName: String) -> String {
        let name = fullName.isEmpty ? command : fullName
        let lower = name.lowercased()
        if lower.hasPrefix("python") { return "python" }
        if lower.hasPrefix("com.docker") || lower == "vpnkit" || lower == "docker-proxy" { return "docker" }
        if lower == "redis-server" { return "redis" }
        if lower == "beam.smp" { return "beam" }
        if lower == "postmaster" { return "postgres" }
        return name
    }

    /// Service label from the executable, e.g. "MySQL" for mysqld.
    private static func serviceLabel(command: String) -> String? {
        let name = command.lowercased()
        switch name {
        case "mysqld": return "MySQL"
        case "mariadbd": return "MariaDB"
        case "postgres", "postmaster": return "PostgreSQL"
        case "redis-server", "valkey-server", "keydb-server": return "Redis"
        case "mongod", "mongos": return "MongoDB"
        case "memcached": return "Memcached"
        case "php-fpm": return "PHP-FPM"
        case "httpd", "apache2": return "Apache"
        case "mailpit", "mailhog": return "Mail catcher"
        case "ollama": return "Ollama"
        default: return name.hasPrefix("php") && name.hasSuffix("fpm") ? "PHP-FPM" : nil
        }
    }

    /// Typical services on well-known dev ports.
    private static let portLabels: [UInt16: String] = [
        80: "HTTP", 443: "HTTPS", 1025: "SMTP", 1313: "Hugo", 3000: "Node/React", 3001: "Dev server",
        3306: "MySQL", 4000: "Phoenix/Jekyll", 4200: "Angular", 4321: "Astro", 5000: "Flask",
        5173: "Vite", 5174: "Vite", 5432: "PostgreSQL", 6006: "Storybook", 6379: "Redis",
        8000: "Django/Laravel", 8025: "Mail catcher", 8080: "HTTP", 8081: "Metro", 8443: "HTTPS",
        8888: "HTTP", 8889: "MySQL", 9000: "PHP-FPM", 9200: "Elasticsearch", 9229: "Node inspector",
        11211: "Memcached", 11434: "Ollama", 19006: "Expo", 27017: "MongoDB", 33060: "MySQL X",
    ]

    /// Friendly service name for a listener: from the executable when it says, else from the port.
    static func serviceLabel(command: String, port: UInt16) -> String? {
        if port == 33060 { return "MySQL X" }
        return serviceLabel(command: command) ?? portLabels[port]
    }

    /// Whether `label` says more than the process name next to it: "MySQL X" or "Vite" do,
    /// "MySQL" beside mysqld, "Apache" beside httpd or a bare "HTTP" don't.
    static func labelAddsInformation(_ label: String, command: String) -> Bool {
        label != "HTTP" && label != "HTTPS" && label != serviceLabel(command: command)
    }

    // MARK: Protocol

    /// Executables that speak something other than HTTP (databases, FastCGI, caches, queues).
    private static let nonHTTPCommands: Set<String> = [
        "mysqld", "mariadbd", "postgres", "postmaster", "redis-server", "redis-sentinel", "valkey-server", "keydb-server",
        "mongod", "mongos", "memcached", "php-fpm", "php-cgi", "nats-server", "influxd", "clickhouse-server",
    ]
    private static let nonHTTPPorts: Set<UInt16> = [
        22, 25, 53, 465, 587, 993, 1025, 1883, 2049, 2181, 3306, 4369, 5432, 5672, 5900,
        6379, 6380, 9092, 9229, 11211, 27017, 33060,
    ]

    /// Whether opening the port in a browser is likely to show something. Only asked about dev
    /// listeners: apps and agents (AirPlay, rapportd, language servers…) never get an Open button.
    static func isLikelyHTTP(command: String, port: UInt16) -> Bool {
        let name = command.lowercased()
        if nonHTTPCommands.contains(name) { return false }
        // Versioned FastCGI daemons ("php83-fpm", "php-fpm8.3").
        if name.hasPrefix("php"), name.contains("fpm") || name.contains("cgi") { return false }
        return !nonHTTPPorts.contains(port)
    }

    // MARK: Context

    /// Install that a server binary comes from, e.g. "MAMP" for /Applications/MAMP/Library/bin/httpd.
    static func stackName(path: String?, command: String, hasValet: Bool) -> String? {
        guard let path else { return nil }
        if path.hasPrefix("/Applications/MAMP") { return "MAMP" }
        if path.contains("XAMPP") || path.contains("/xamppfiles/") { return "XAMPP" }
        if path.contains("/Herd") { return "Herd" }
        if path.contains("DBngin") { return "DBngin" }
        if path.contains("/Local/lightning-services/") { return "Local" }
        if path.contains("/Postgres.app/") { return "Postgres.app" }
        if let runtime = containerRuntime(command: command, path: path) { return runtime }
        if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/Cellar/") || path.hasPrefix("/usr/local/opt/") {
            let name = command.lowercased()
            if hasValet && (name == "nginx" || name == "php-fpm" || name == "dnsmasq") { return "Valet" }
            // "node · Homebrew" says nothing; only services (nginx, mysqld, redis…) get the hint.
            return isRuntime(name) ? nil : "Homebrew"
        }
        return nil
    }

    /// Language runtimes: where they were installed from says nothing about what they serve.
    private static func isRuntime(_ name: String) -> Bool {
        if ["node", "bun", "deno", "ruby", "php", "java", "dotnet", "dart", "beam.smp", "python", "python3"].contains(name) { return true }
        // Versioned runtimes ("python3.13", "php8.3"), but not "php83-fpm", which is a service.
        return ["python", "node", "ruby", "java"].contains { isVersioned(name, of: $0) }
            || (isVersioned(name, of: "php") && !name.hasSuffix("fpm") && !name.hasSuffix("cgi"))
    }

    /// Web roots outside the home folder whose sub-folders are projects.
    private static let webRoots = [
        "/Applications/MAMP/htdocs/", "/Applications/XAMPP/htdocs/", "/Applications/XAMPP/xamppfiles/htdocs/",
        "/Library/WebServer/Documents/", "/opt/homebrew/var/www/", "/usr/local/var/www/",
        "/var/www/", "/private/var/www/", "/srv/", "/Volumes/", "/Users/Shared/",
    ]

    /// Project folder for a working directory: its last component when it lies in the home folder
    /// (but not the home folder itself, ~/Library or a hidden folder) or in a known web root.
    static func projectFolder(workingDirectory cwd: String?, home: String) -> String? {
        guard var cwd, cwd.count > 1 else { return nil }
        while cwd.count > 1 && cwd.hasSuffix("/") { cwd.removeLast() }
        let inWebRoot = webRoots.contains { cwd.hasPrefix($0) }
        if !inWebRoot {
            guard cwd.hasPrefix(home + "/") else { return nil }
            let firstComponent = cwd.dropFirst(home.count + 1).split(separator: "/").first ?? ""
            if firstComponent.isEmpty || firstComponent == "Library" || firstComponent.hasPrefix(".") { return nil }
        }
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? nil : last
    }
}
