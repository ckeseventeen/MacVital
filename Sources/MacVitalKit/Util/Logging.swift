import Foundation
import OSLog

public enum Log {
    private static let subsystem = "com.macvital.MacVital"

    public static let rules = Logger(subsystem: subsystem, category: "rules")
    public static let scan = Logger(subsystem: subsystem, category: "scan")
    public static let ai = Logger(subsystem: subsystem, category: "ai")
    public static let quarantine = Logger(subsystem: subsystem, category: "quarantine")
    public static let helper = Logger(subsystem: subsystem, category: "helper")
    public static let app = Logger(subsystem: subsystem, category: "app")

    /// Paths in logs are redacted by default — logs get attached to bug reports.
    public static func path(_ path: String) -> String { PathRedaction.redact(path) }
}
