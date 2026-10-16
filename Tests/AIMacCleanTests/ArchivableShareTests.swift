import XCTest

import AIMacCleanDomain

/// 「可归档占比」的唯一定义（PRD §9、§14.1；issue #28）。
///
/// 概览页与分类明细页此前各写一套门槛、零值守卫与百分比格式化，可能对同一台工具
/// 给出矛盾的说法。现在两者都消费 `ArchivableShare`，这组用例钉住它本身：
/// 门槛是 1%（严格小于）、「极小」要求确实有可归档字节、百分比至多两位小数。
final class ArchivableShareTests: XCTestCase {

    // MARK: - 百分比文案

    func test占比至多两位小数并去掉尾随0() {
        XCTAssertEqual(ArchivableShare.percentText(0.0015), "0.15%", "PRD §14.1 的实测数字要原样站得住")
        XCTAssertEqual(ArchivableShare.percentText(0.5), "50%")
        XCTAssertEqual(ArchivableShare.percentText(0), "0%")
        XCTAssertEqual(ArchivableShare.percentText(1), "100%")
        XCTAssertEqual(ArchivableShare.percentText(0.6113), "61.13%")
        XCTAssertEqual(ArchivableShare.percentText(0.496285), "49.63%")
    }

    func test负数占比不产生负号() {
        // 占比是算出来的展示值，不该出现负数；真出现时按 0 显示，不吓用户。
        XCTAssertEqual(ArchivableShare.percentText(-0.1), "0%")
    }

    func test非零但不足百分之零点零一显示成小于而非0() {
        // 「有，但极小」与「一点都没有」是两件事（PRD §9 的诚实展示）。
        // 概览页此前用 `%.2f`，这里会显示成 `0%`——明细页的 `<0.01%` 才是诚实的那个。
        XCTAssertEqual(ArchivableShare.percentText(0.0000001), "<0.01%")
        XCTAssertEqual(ArchivableShare.percentText(0.00004), "<0.01%", "0.004% 不足一个基点")
        XCTAssertEqual(ArchivableShare.percentText(0.0001), "0.01%", "正好一个基点就照常显示")
    }

    // MARK: - 占比与「极小」

    func test占比是可归档除以总量且总量为零时为零() {
        XCTAssertEqual(ArchivableShare.share(of: 15, totalBytes: 10_000), 0.0015, accuracy: 1e-12)
        XCTAssertEqual(ArchivableShare.share(of: 0, totalBytes: 1_000), 0, accuracy: 1e-12)
        XCTAssertEqual(ArchivableShare.share(of: 1, totalBytes: 0), 0, accuracy: 1e-12, "不能返回 NaN")
    }

    func test极小要求确实有可归档字节且严格低于门槛() {
        XCTAssertTrue(ArchivableShare.isNegligible(archivableBytes: 15, totalBytes: 10_000), "0.15% 是点名要标注的那种")

        // 0 字节可归档不叫「极小」，叫「没有」——两页必须同一条判定。
        XCTAssertFalse(ArchivableShare.isNegligible(archivableBytes: 0, totalBytes: 5_000_000))

        // 门槛是严格小于：正好 1% 不算极小，差一个字节才算。
        XCTAssertFalse(ArchivableShare.isNegligible(archivableBytes: 10_000, totalBytes: 1_000_000))
        XCTAssertTrue(ArchivableShare.isNegligible(archivableBytes: 9_999, totalBytes: 1_000_000))

        // 0.9999% 仍是极小：判定看原始比值，不看四舍五入后的 `1%` 文案。
        XCTAssertTrue(ArchivableShare.isNegligible(archivableBytes: 9_999, totalBytes: 1_000_000))
        XCTAssertEqual(ArchivableShare.percentText(0.009999), "1%", "文案可以四舍五入，判定不行")
    }
}
