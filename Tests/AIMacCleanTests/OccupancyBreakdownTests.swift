import XCTest

import AIMacCleanDomain
import AIMacCleanRules

/// issue #28 的展示拼装层：深扫报告 → 概览页要摆出来的「四类分列」与「可归档占比」。
///
/// 钉子钉在三件事上：
/// 1. **四行齐全、顺序固定**（PRD §5.1 的表格顺序）——没有数据的类别也要占一行，
///    否则界面上的分类会随着数据有无而跳动。
/// 2. **占比与极小判定**（PRD §9、§14.1）：Claude Code 实测 0.15% 必须被标成极小；
///    正常占比不许被标；一个字节都不可归档的（0）不叫「极小」，它有自己的说法。
/// 3. 数字都从**手算的字面量**来（§14.1 的实测口径），不是拿被测代码重算一遍。
final class OccupancyBreakdownTests: XCTestCase {

    // MARK: - 夹具

    /// 一台工具的四类占用（只列有数据的类别，和深扫的输出形状一致）。
    private func tool(
        id: String,
        bytes: [DataCategory: Int64],
        toolRootPath: String = "/tmp/fake/.tool"
    ) -> ToolScanReport {
        let categories = DataCategory.displayOrder.compactMap { category -> CategoryOccupancy? in
            guard let value = bytes[category] else { return nil }
            return CategoryOccupancy(
                category: category,
                occupancy: Occupancy(bytes: value, fileCount: 1),
                holdingDirectoryCount: 1,
                summaries: []
            )
        }
        return ToolScanReport(
            toolID: id,
            displayName: id,
            toolRootPath: toolRootPath,
            occupancy: Occupancy.sum(categories.map(\.occupancy)),
            categories: categories,
            roots: [ToolRootOccupancy(path: toolRootPath, role: .toolRoot, occupancy: Occupancy.sum(categories.map(\.occupancy)))],
            holdingDirectoryCount: categories.count,
            unreadable: [],
            unfollowedLinks: []
        )
    }

    /// PRD §14.1 的 Claude Code 口径：可归档 404 KB 对上整台 277 M（这里按 0.15% 等比缩小）。
    private var claudeLike: ToolScanReport {
        tool(id: "claude-code", bytes: [.archivableSession: 15, .cacheAndLog: 9_985])
    }

    /// 一台正常占比的工具：可归档 1 MB、其余 1 MB，各占一半。
    private var halfArchivable: ToolScanReport {
        tool(id: "half", bytes: [.archivableSession: 1_000_000, .cacheAndLog: 1_000_000])
    }

    /// 一个字节都不可归档的工具（Cursor AppSupport 那种只展示根）。
    private var nothingArchivable: ToolScanReport {
        tool(id: "display-only", bytes: [.protected: 5_000])
    }

    // MARK: - 四类分列

    func test工具的四类分列齐全且顺序固定() {
        let rows = claudeLike.categoryLines

        // 领域层只给结构（类别 + 占用 + 本阶段能否归档），**不携带文案**：
        // 类别名与处理方式在界面层的 `CategoryCopy`（本地化目录），概览与明细两页同源。
        XCTAssertEqual(rows.map(\.categoryID), ["archivableSession", "cacheAndLog", "protected", "uncertain"])
        XCTAssertEqual(
            rows.map(\.category),
            [.archivableSession, .cacheAndLog, .protected, .uncertain],
            "顺序是 PRD §5.1 的表格顺序"
        )
        // 没有数据的类别给 0，而不是从列表里消失。
        XCTAssertEqual(rows.map(\.occupancy.bytes), [15, 9_985, 0, 0])
        // M2 四类都不可归档（归档是 M3）。
        XCTAssertEqual(rows.map(\.isArchivableNow), [false, false, false, false])
    }

    func test全体四类分列是各工具逐类求和() {
        let report = DeepScanReport(toolReports: [claudeLike, halfArchivable, nothingArchivable])
        let rows = report.categoryLines

        XCTAssertEqual(rows.map(\.categoryID), ["archivableSession", "cacheAndLog", "protected", "uncertain"])
        // 手算：可归档 15 + 1_000_000 + 0；缓存 9_985 + 1_000_000；受保护 5_000。
        XCTAssertEqual(rows.map(\.occupancy.bytes), [1_000_015, 1_009_985, 5_000, 0])
        XCTAssertEqual(Occupancy.sum(rows.map(\.occupancy)), report.totalOccupancy, "四类之和必须等于总占用")
    }

    // MARK: - 可归档占比与「极小」

    func test工具的占比按总占用算() {
        XCTAssertEqual(claudeLike.archivableShare, 0.0015, accuracy: 1e-12, "PRD §14.1 的 0.15%")
        XCTAssertEqual(halfArchivable.archivableShare, 0.5, accuracy: 1e-12)
        XCTAssertEqual(nothingArchivable.archivableShare, 0, accuracy: 1e-12)
    }

    func test全体占比是全体可归档除以全体总占用() {
        let report = DeepScanReport(toolReports: [claudeLike, halfArchivable, nothingArchivable])

        XCTAssertEqual(report.totalBytes, 2_015_000, "手算：10_000 + 2_000_000 + 5_000")
        XCTAssertEqual(report.archivableOccupancy.bytes, 1_000_015)
        XCTAssertEqual(report.archivableShare, 0.496285, accuracy: 1e-6)
    }

    func test占比极小的工具被标成极小() {
        XCTAssertTrue(claudeLike.isArchivableShareNegligible, "0.15% 就是 PRD §14.1 点名要如实标注的那种")
    }

    func test正常占比不被标成极小() {
        XCTAssertFalse(halfArchivable.isArchivableShareNegligible)
    }

    func test一个字节都不可归档时不叫极小() {
        // 0 不是「极小」，是「没有」。两者都要如实，但不能用同一个词（诚实展示）。
        XCTAssertFalse(nothingArchivable.isArchivableShareNegligible)
    }

    func test总占用为零的工具不产生占比也不标极小() {
        let empty = tool(id: "empty", bytes: [:])
        XCTAssertEqual(empty.occupancy.bytes, 0)
        XCTAssertEqual(empty.archivableShare, 0)
        XCTAssertFalse(empty.isArchivableShareNegligible)
    }
}
