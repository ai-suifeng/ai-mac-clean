import Foundation
import XCTest

import AIMacCleanDomain

@testable import AIMacCleanUI

/// Seam：分类明细的**呈现层**（issue #27）。
///
/// 一条工具的四类占用怎么变成界面上的一行行文字，全在这里定死：
/// 类别名与处理方式取自 PRD §5.1（L10n，zh/en）、尺寸统一 `ByteSizeFormatter`、
/// 占比按总占用算、不可归档的三类必须带「只展示」的处理说明、
/// 可归档占比极小的工具必须被如实标注、读不到的位置逐条列出。
///
/// 用例只给固定报告，不碰磁盘（深扫本身由 `DeepScanningTests` 在它自己的 seam 上钉住）。
final class ClassificationDetailPresentationTests: XCTestCase {

    private let homeDirectory = "/Users/example"

    private func detail(
        _ report: ToolScanReport,
        language: AppLanguage? = .simplifiedChinese
    ) -> ToolClassificationDetail {
        ClassificationDetailPresenter.detail(for: report, homeDirectory: homeDirectory, language: language)
    }

    // MARK: - 验收 1：每一行（类别、字节数、占比）与预期一致

    func test每一行按PRD顺序给出类别字节数文件数与占比() {
        let detail = detail(ClassificationDetailFixture.claudeCode())

        XCTAssertEqual(
            detail.categoryRows.map(\.category),
            [.archivableSession, .cacheAndLog, .protected, .uncertain],
            "四类按 PRD §5.1 表格顺序排列，不按占用大小重排"
        )
        XCTAssertEqual(
            detail.categoryRows.map(\.sizeText),
            ["404 KB", "6 MB", "270 MB", "620 KB"],
            "尺寸一律走 ByteSizeFormatter（1024 进制），界面不自己算"
        )
        XCTAssertEqual(
            detail.categoryRows.map(\.fileCountText),
            ["4 个文件", "12 个文件", "1234 个文件", "3 个文件"]
        )
        XCTAssertEqual(
            detail.categoryRows.map(\.shareText),
            ["0.14%", "2.17%", "97.47%", "0.22%"],
            "占比按本工具总占用算——受保护的大头必须显眼"
        )
        XCTAssertEqual(detail.totalSizeText, "277 MB")
        XCTAssertEqual(detail.totalFileCountText, "1253 个文件")
    }

    // MARK: - 验收 2：三类不可归档各自带 PRD §5.1 的处理说明（L10n，zh + en）

    func test三类不可归档逐字带PRD五点一的处理说明() {
        let zh = detail(ClassificationDetailFixture.claudeCode())

        // 文案逐字取自 PRD §5.1 的「处理」一列，也与领域层同源——
        // 界面不能自己把「永不触碰」改写成别的话（issue #11 的承诺在界面上兑现）。
        XCTAssertEqual(zh.row(.cacheAndLog)?.handlingText, "只展示大小，不动")
        XCTAssertEqual(zh.row(.protected)?.handlingText, "永不触碰，仅展示")
        XCTAssertEqual(zh.row(.uncertain)?.handlingText, "锁定，仅展示大小")

        XCTAssertEqual(zh.row(.cacheAndLog)?.handlingText, DataCategory.cacheAndLog.handling)
        XCTAssertEqual(zh.row(.protected)?.handlingText, DataCategory.protected.handling)
        XCTAssertEqual(zh.row(.uncertain)?.handlingText, DataCategory.uncertain.handling)

        let en = detail(ClassificationDetailFixture.claudeCode(), language: .english)
        XCTAssertEqual(en.row(.cacheAndLog)?.handlingText, "Shown only, never touched")
        XCTAssertEqual(en.row(.protected)?.handlingText, "Never touched, shown only")
        XCTAssertEqual(en.row(.uncertain)?.handlingText, "Locked, size shown only")
        XCTAssertEqual(en.row(.protected)?.nameText, "Protected")
    }

    func test本阶段四类都不声称现在可归档且可归档一行带阶段说明() {
        let detail = detail(ClassificationDetailFixture.claudeCode())

        XCTAssertTrue(
            detail.categoryRows.allSatisfy { !$0.isArchivableNow },
            "M2 没有任何一类现在能归档（`DataCategory.isArchivableNow` 一律为假），界面不得给出可点的收益暗示"
        )
        XCTAssertEqual(
            detail.row(.archivableSession)?.noteText,
            "归档能力在后续里程碑落地；当前版本不会移动或删除任何文件。"
        )
        XCTAssertNil(detail.row(.protected)?.noteText, "处理方式已经说明了，不必再叠一句")
        XCTAssertEqual(
            detail.row(.archivableSession)?.handlingText, "支持归档",
            "类别口径仍按 PRD §5.1；「现在就能归档」的误解由阶段说明挡住"
        )
    }

    // MARK: - 验收 3：可归档占比极小的如实标注（PRD §9、§14.1）

    func test可归档占比极小时出现如实标注正常占比时不出现() {
        // PRD §14.1 的 Claude Code：可归档 404K / 277M = 0.14%。
        let claudeCode = detail(ClassificationDetailFixture.claudeCode())
        XCTAssertEqual(claudeCode.archivableShareText, "0.14%")
        XCTAssertTrue(claudeCode.isArchivableShareTiny)
        XCTAssertEqual(
            claudeCode.tinyArchivableShareNotice,
            "可归档占比极小：这个工具的占用几乎都不在可归档范围内，归档它不会释放多少空间。"
        )

        // 正常占比（Codex 形状：可归档是大头）不出现任何标注。
        let codex = detail(
            ClassificationDetailFixture.tool(archivableBytes: ClassificationDetailFixture.bytes(292),
                                              protectedBytes: ClassificationDetailFixture.bytes(195))
        )
        XCTAssertEqual(codex.archivableShareText, "59.96%")
        XCTAssertFalse(codex.isArchivableShareTiny)
        XCTAssertNil(codex.tinyArchivableShareNotice)

        // 阈值边界：正好 1% 不算极小，差一个字节才算（阈值是严格小于）。
        let exactlyOnePercent = detail(
            ClassificationDetailFixture.tool(archivableBytes: ClassificationDetailFixture.bytes(1),
                                              protectedBytes: ClassificationDetailFixture.bytes(99))
        )
        XCTAssertEqual(exactlyOnePercent.archivableShareText, "1%")
        XCTAssertFalse(exactlyOnePercent.isArchivableShareTiny)

        let justUnder = detail(
            ClassificationDetailFixture.tool(archivableBytes: ClassificationDetailFixture.bytes(1) - 1,
                                              protectedBytes: ClassificationDetailFixture.bytes(99))
        )
        XCTAssertTrue(justUnder.isArchivableShareTiny)
        XCTAssertNotNil(justUnder.tinyArchivableShareNotice)
    }

    func test完全空的工具不出现极小占比标注() {
        // 一个字节都没有的工具不该被念一句「可归档占比极小」——那是在提醒一件不存在的事。
        let empty = detail(ClassificationDetailFixture.report(categories: []))
        XCTAssertEqual(empty.archivableShareText, "0%")
        XCTAssertFalse(empty.isArchivableShareTiny)
        XCTAssertNil(empty.tinyArchivableShareNotice)
        XCTAssertTrue(empty.categoryRows.isEmpty, "没有数据的类别不留占位空行")
    }
}
