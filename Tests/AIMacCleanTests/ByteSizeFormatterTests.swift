import XCTest

@testable import AIMacCleanCore

/// Seam A：`ByteSizeFormatter` 是全应用唯一的体积格式化入口（PRD §9「大小统一用 ByteCountFormatter」）。
///
/// 期望值是本机实测后钉死的字面量（见 issue #8 说明），不是按实现算法复算的，
/// 因此断言能真正与实现分歧：换一种格式化策略就会红。
final class ByteSizeFormatterTests: XCTestCase {

    func test小于1KB的字节数不四舍五入成KB() {
        // 默认 .file 风格会把 1023 B 显示成 "1 KB"，本应用不允许这种夸大。
        XCTAssertEqual(ByteSizeFormatter.string(from: 0), "0 B")
        XCTAssertEqual(ByteSizeFormatter.string(from: 1), "1 B")
        XCTAssertEqual(ByteSizeFormatter.string(from: 1023), "1023 B")
    }

    func test整1024进位到下一档且不带多余小数() {
        XCTAssertEqual(ByteSizeFormatter.string(from: 1024), "1 KB")
        XCTAssertEqual(ByteSizeFormatter.string(from: 1024 * 1024), "1 MB")
        XCTAssertEqual(ByteSizeFormatter.string(from: 1024 * 1024 * 1024), "1 GB")
        XCTAssertEqual(ByteSizeFormatter.string(from: 1024 * 1024 * 1024 * 1024), "1 TB")
    }

    func test不足一个单位的量按同一口径四舍五入() {
        // 1536 B = 1.5 KB，向上一档显示为 2 KB，与 macOS 系统「显示简介」一致。
        XCTAssertEqual(ByteSizeFormatter.string(from: 1536), "2 KB")
        XCTAssertEqual(ByteSizeFormatter.string(from: 1024 * 1024 * 3 / 2), "1.5 MB")
        XCTAssertEqual(ByteSizeFormatter.string(from: 1024 * 1024 * 1024 * 7 / 2), "3.5 GB")
    }

    func test与本机实测口径一致() {
        // PRD §14.1 实测：`~/.codex` 12G、范围内可归档 7.3G。
        XCTAssertEqual(ByteSizeFormatter.string(from: 12 * 1024 * 1024 * 1024), "12 GB")
        XCTAssertEqual(ByteSizeFormatter.string(from: 7_838_315_315), "7.3 GB")
    }

    func test负数不被当作可展示体积() {
        XCTAssertEqual(ByteSizeFormatter.string(from: -1), "0 B")
    }
}
