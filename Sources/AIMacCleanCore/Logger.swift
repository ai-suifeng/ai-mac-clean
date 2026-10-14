import Foundation

/// 日志级别，顺序即严重程度。
public enum LogLevel: String, CaseIterable, Comparable, Sendable {
    case debug
    case info
    case warning
    case error

    private var severity: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.severity < rhs.severity
    }
}

/// 日志出口。上层与测试都通过它拿到日志，而不是去抓 stderr。
public protocol LogSink: AnyObject {
    func write(level: LogLevel, message: String)
}

/// 默认出口：写 stderr。
///
/// 刻意不接 os_log / NSLog：本项目「应用运行全程无网络连接」（PRD §8.3），
/// 且日志内容会包含真实路径，集中在一个出口便于后续替换与静默。
public final class StandardErrorLogSink: LogSink {
    public init() {}

    public func write(level: LogLevel, message: String) {
        FileHandle.standardError.write(Data("[\(level.rawValue)] \(message)\n".utf8))
    }
}

/// Core 层的日志门面：低于 `minimumLevel` 的消息直接丢弃。
public final class Logger {
    private let sink: LogSink
    private let minimumLevel: LogLevel

    public init(sink: LogSink = StandardErrorLogSink(), minimumLevel: LogLevel = .info) {
        self.sink = sink
        self.minimumLevel = minimumLevel
    }

    public func debug(_ message: String) { log(.debug, message) }
    public func info(_ message: String) { log(.info, message) }
    public func warning(_ message: String) { log(.warning, message) }
    public func error(_ message: String) { log(.error, message) }

    public func log(_ level: LogLevel, _ message: String) {
        guard level >= minimumLevel else { return }
        sink.write(level: level, message: message)
    }
}
