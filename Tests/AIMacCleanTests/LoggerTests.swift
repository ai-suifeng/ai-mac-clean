import XCTest

@testable import AIMacCleanCore

/// Seam C：日志的公共出口是 `LogSink` 协议，测试在这里放替身，不去抓 stderr。
private final class RecordingLogSink: LogSink {
    private(set) var lines: [String] = []

    func write(level: LogLevel, message: String) {
        lines.append("[\(level.rawValue)] \(message)")
    }
}

final class LoggerTests: XCTestCase {

    func test默认级别只记录警告及以上() {
        let sink = RecordingLogSink()
        let logger = Logger(sink: sink, minimumLevel: .warning)

        logger.debug("调试细节")
        logger.info("扫描开始")
        logger.warning("目标卷剩余空间不足")
        logger.error("归档校验失败")

        XCTAssertEqual(
            sink.lines,
            [
                "[warning] 目标卷剩余空间不足",
                "[error] 归档校验失败",
            ]
        )
    }

    func test级别可放宽到调试() {
        let sink = RecordingLogSink()
        let logger = Logger(sink: sink, minimumLevel: .debug)

        logger.debug("浅扫完成")

        XCTAssertEqual(sink.lines, ["[debug] 浅扫完成"])
    }

    func test级别顺序为debug到error() {
        XCTAssertTrue(LogLevel.debug < LogLevel.info)
        XCTAssertTrue(LogLevel.info < LogLevel.warning)
        XCTAssertTrue(LogLevel.warning < LogLevel.error)
        XCTAssertEqual(LogLevel.allCases, [.debug, .info, .warning, .error])
    }
}
