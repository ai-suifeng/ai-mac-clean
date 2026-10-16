import Foundation
import XCTest

import AIMacCleanDomain
import AIMacCleanRules

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
}
