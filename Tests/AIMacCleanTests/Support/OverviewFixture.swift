import Foundation
import XCTest

import AIMacCleanDomain
import AIMacCleanRules

/// 概览页测试的假深扫结果。视图模型的测试**不跑磁盘扫描**：扫描本身已经由
/// `DeepScanningTests` / `DeepScanServiceTests` 钉住，这里只关心「拿到报告与容量之后，
/// 界面摆出什么」。
final class StubOccupancyScanner: ConfirmedToolScanning {

    /// 被测代码实际交给深扫的那批确认记录，供断言「只扫已确认的工具」。
    private(set) var receivedRecords: [ConfirmationRecord] = []

    /// 按收到的记录给出报告。默认返回一份固定报告。
    var reportFor: ([ConfirmationRecord]) -> DeepScanReport

    init(report: DeepScanReport) {
        self.reportFor = { _ in report }
    }

    init(reportFor: @escaping ([ConfirmationRecord]) -> DeepScanReport) {
        self.reportFor = reportFor
    }

    func scan(_ records: [ConfirmationRecord]) -> DeepScanReport {
        receivedRecords = records
        return reportFor(records)
    }
}

/// 固定容量读数：只回一个值，不看路径（概览页的测试不碰真磁盘）。
struct StubCapacityReader: VolumeCapacityReading {

    let reading: VolumeCapacity

    func capacity(ofVolumeContaining path: String) -> VolumeCapacity { reading }
}

/// 概览页夹具：临时目录上的确认存储（不为持久化单开 seam）+ 构造报告的小工具。
final class OverviewPageFixture {

    let applicationSupport: TemporaryDirectoryFixture
    let home: TemporaryDirectoryFixture
    let store: JSONConfirmationStore
    let homePath: String

    init(named name: String = "overview-page") throws {
        applicationSupport = try TemporaryDirectoryFixture(named: name + "-store")
        home = try TemporaryDirectoryFixture(named: name + "-home")
        store = JSONConfirmationStore(applicationSupportRoot: applicationSupport.url)
        homePath = home.url.path
    }

    func remove() {
        applicationSupport.remove()
        home.remove()
    }

    /// 落一条确认记录（走真实存储）。
    func confirm(id: String?, root: String) throws {
        try store.decide(
            toolIdentifier: id,
            toolRootPath: root,
            decision: .confirmed,
            signals: .none,
            decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// 夹具主目录下的一个工具根路径。
    func toolRoot(_ name: String) -> String { homePath + "/" + name }
}

/// 直接拼一份 `ToolScanReport`（纯值，不碰磁盘）。
///
/// `bytes` 是这台工具的**全部**分类占用（含仅展示根里的数据）；
/// `displayOnlyBytes` 只是分根清单里「仅展示」那一份，用来验证界面如实分列。
enum OverviewFixture {

    static func toolReport(
        id: String,
        displayName: String? = nil,
        toolRootPath: String,
        bytes: [DataCategory: Int64],
        fileCounts: [DataCategory: Int] = [:],
        displayOnlyBytes: Int64 = 0,
        displayOnlyCategory: DataCategory = .uncertain,
        displayOnlyFileCount: Int = 0
    ) -> ToolScanReport {
        var bytes = bytes
        var fileCounts = fileCounts
        if displayOnlyBytes > 0 {
            bytes[displayOnlyCategory, default: 0] += displayOnlyBytes
            fileCounts[displayOnlyCategory, default: 0] += displayOnlyFileCount
        }

        let categories = DataCategory.displayOrder.compactMap { category -> CategoryOccupancy? in
            guard let value = bytes[category], value > 0 || (fileCounts[category] ?? 0) > 0 else { return nil }
            return CategoryOccupancy(
                category: category,
                occupancy: Occupancy(bytes: value, fileCount: fileCounts[category] ?? 0),
                holdingDirectoryCount: 1,
                summaries: []
            )
        }
        let total = Occupancy.sum(categories.map(\.occupancy))
        let mainOccupancy = Occupancy(bytes: total.bytes - displayOnlyBytes, fileCount: total.fileCount - displayOnlyFileCount)
        var roots = [ToolRootOccupancy(path: toolRootPath, role: .toolRoot, occupancy: mainOccupancy)]
        if displayOnlyBytes > 0 {
            roots.append(
                ToolRootOccupancy(
                    path: toolRootPath + "-display-only",
                    role: .displayOnly,
                    occupancy: Occupancy(bytes: displayOnlyBytes, fileCount: displayOnlyFileCount)
                )
            )
        }

        return ToolScanReport(
            toolID: id,
            displayName: displayName ?? id,
            toolRootPath: toolRootPath,
            occupancy: total,
            categories: categories,
            roots: roots,
            holdingDirectoryCount: categories.count,
            unreadable: [],
            unfollowedLinks: []
        )
    }

    static func report(_ tools: [ToolScanReport]) -> DeepScanReport {
        DeepScanReport(toolReports: tools.sorted { $0.toolID < $1.toolID })
    }
}
