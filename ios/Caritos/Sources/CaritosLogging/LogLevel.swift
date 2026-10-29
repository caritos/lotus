public enum LogLevel: Int, Comparable, Sendable {
    case debug, info, warning, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }
}
