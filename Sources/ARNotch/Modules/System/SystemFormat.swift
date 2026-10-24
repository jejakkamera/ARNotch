import Foundation

/// Compact, locale-independent number formatting for the System module.
/// Network rates use decimal units (1 KB = 1000 B); memory uses binary units labelled GB/MB, like Activity Monitor.
enum SystemFormat {
    /// "0 KB/s", "340 KB/s", "1.2 MB/s", "12 MB/s", "1.1 GB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        let (value, unit) = scaledRate(bytesPerSecond)
        return "\(value) \(unit)B/s"
    }

    /// Header form without "/s" and spaces: "0K", "340K", "1.2M", "12M", "1.1G" (at most 4 characters).
    static func compactRate(_ bytesPerSecond: Double) -> String {
        let (value, unit) = scaledRate(bytesPerSecond)
        return "\(value)\(unit)"
    }

    private static func scaledRate(_ bytesPerSecond: Double) -> (String, String) {
        let bytes = bytesPerSecond.isFinite ? max(bytesPerSecond, 0) : 0
        let kilo = bytes / 1_000
        if kilo.rounded() < 1_000 { return ("\(Int(kilo.rounded()))", "K") }
        let mega = bytes / 1_000_000
        if mega < 9.95 { return (oneDecimal(mega), "M") }
        if mega.rounded() < 1_000 { return ("\(Int(mega.rounded()))", "M") }
        let giga = bytes / 1_000_000_000
        return (giga < 9.95 ? oneDecimal(giga) : "\(Int(giga.rounded()))", "G")
    }

    /// Memory size: "340 MB", "1.8 GB", "12.4 GB".
    static func memory(_ bytes: UInt64) -> String {
        let mib = Double(bytes) / 1_048_576
        if mib.rounded() < 1_000 { return "\(Int(mib.rounded())) MB" }
        return "\(oneDecimal(mib / 1_024)) GB"
    }

    /// Gigabytes with one decimal, without the unit: "11.2", "13.0".
    static func gigabytes(_ bytes: UInt64) -> String {
        oneDecimal(Double(bytes) / 1_073_741_824)
    }

    /// Installed RAM without the unit: whole when exact ("16"), else one decimal.
    static func installedGigabytes(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824
        return abs(gib - gib.rounded()) < 0.05 ? "\(Int(gib.rounded()))" : oneDecimal(gib)
    }

    /// Whole percent: "0%", "12%", "100%".
    static func percent(_ value: Double) -> String {
        "\(Int((value.isFinite ? max(value, 0) : 0).rounded()))%"
    }

    /// Per-process CPU like Activity Monitor: "0.4%", "9.8%", "34%", "212%".
    static func processCPU(_ value: Double) -> String {
        let clamped = value.isFinite ? max(value, 0) : 0
        return clamped < 9.95 ? "\(oneDecimal(clamped))%" : "\(Int(clamped.rounded()))%"
    }

    /// "3d 4h", "5h 12m", "42m".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(seconds, 0)) / 60
        let days = minutes / 1_440
        let hours = minutes / 60 % 24
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    private static func oneDecimal(_ value: Double) -> String {
        let tenths = Int((value * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }
}
