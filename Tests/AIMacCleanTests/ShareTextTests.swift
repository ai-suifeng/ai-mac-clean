import XCTest

import AIMacCleanUI

/// 占比文案（issue #28）。
///
/// PRD §14.1 点名的 Claude Code 是 **0.15%**——一位小数会把它显示成「0.2%」（夸大），
/// 整数会显示成「0%」（假装没有），所以至多两位小数；同时不许出现「50.00%」这种噪声。
final class ShareTextTests: XCTestCase {

    func test占比至多两位小数并去掉尾随0() {
        XCTAssertEqual(ShareText.string(fromShare: 0.0015), "0.15%", "PRD §14.1 的实测数字要原样站得住")
        XCTAssertEqual(ShareText.string(fromShare: 0.5), "50%")
        XCTAssertEqual(ShareText.string(fromShare: 0), "0%")
        XCTAssertEqual(ShareText.string(fromShare: 1), "100%")
        XCTAssertEqual(ShareText.string(fromShare: 0.6113), "61.13%")
        XCTAssertEqual(ShareText.string(fromShare: 0.496285), "49.63%")
    }

    func test负数占比不产生负号() {
        // 占比是算出来的展示值，不该出现负数；真出现时按 0 显示，不吓用户。
        XCTAssertEqual(ShareText.string(fromShare: -0.1), "0%")
    }
}
