import Foundation

import AIMacCleanDomain

/// 工具分类明细的**呈现层**（issue #27；PRD §5.1、§9）。
///
/// 这一层只做一件事：把一份深扫结果（`ToolScanReport`）变成界面上的一行行文字。
/// 它不读磁盘、不判定分类、不重算占用——分类的判定在规则层与深扫器里，
/// 这里只负责「怎么说」。
///
/// ## 诚实展示（PRD §5.1、§9、§14.1）
///
/// 1. **不可归档的三类必须带处理说明**：缓存与日志「只展示大小，不动」、
///    受保护「永不触碰，仅展示」、不确定「锁定，仅展示大小」——文案逐字取自
///    PRD §5.1，走 `L10n`（zh/en），不在视图里硬编码。
/// 2. **可归档会话在本阶段也不写盘**：类别名与处理方式照 PRD §5.1 给，
///    但另附一句阶段说明（归档能力是 M3），不让「支持归档」四个字被读成现在就有的收益。
/// 3. **可归档占比极小要如实标注**：PRD §9 点名 Claude Code 只有 0.15%，
///    界面上给一句「可归档占比极小」，不用大字号或措辞暗示收益。
/// 4. **读不到的位置逐条列出**（PRD §4.4），不让它们悄悄消失。
/// 5. **不做任何压缩率估算**：那是 M3 的事（§9、§6.3）。
public enum ClassificationDetailPresenter {

    /// 「可归档占比极小」的判定阈值：低于 1% 就标注（PRD §9 只给了「极小」这个定性，
    /// 这里取本票验收里写明的 1% 作为展示用的分界）。
    public static let tinyArchivableShareThreshold = 0.01

    /// 每个类别最多列几条子路径明细：界面是给人看的，不是 `du` 的输出。
    public static let maxSummariesPerCategory = 5

    /// 把一台工具的深扫结果摊成界面用的明细。
    ///
    /// - Parameters:
    ///   - report: 一台工具的深扫报告。
    ///   - homeDirectory: `~` 缩写用的主目录（由调用方注入，测试才不用碰真实主目录）。
    ///   - language: 界面语言；`nil` 跟随 `L10n` 的默认（取不到时落到简体中文）。
    public static func detail(
        for report: ToolScanReport,
        homeDirectory: String,
        language: AppLanguage? = nil
    ) -> ToolClassificationDetail {
        let totalBytes = report.occupancy.bytes

        // 按 PRD §5.1 的表格顺序摆：界面顺序不随占用大小变，
        // 否则「受保护」会顶到第一行，读起来像是推荐先处理它。
        let rows = DataCategory.displayOrder.compactMap { category -> ClassificationCategoryRow? in
            guard let occupancy = report.category(category) else { return nil }
            return row(
                for: occupancy,
                totalBytes: totalBytes,
                language: language
            )
        }

        return ToolClassificationDetail(
            toolID: report.toolID,
            displayName: report.displayName,
            rootDisplayPath: ToolRootDisplay.abbreviated(report.toolRootPath, homeDirectory: homeDirectory),
            totalSizeText: report.occupancy.sizeText,
            totalFileCountText: fileCountText(report.occupancy.fileCount, language: language),
            categoryRows: rows
        )
    }

    // MARK: - 一行

    private static func row(
        for occupancy: CategoryOccupancy,
        totalBytes: Int64,
        language: AppLanguage?
    ) -> ClassificationCategoryRow {
        ClassificationCategoryRow(
            category: occupancy.category,
            nameText: nameText(for: occupancy.category, language: language),
            sizeText: occupancy.occupancy.sizeText,
            fileCountText: fileCountText(occupancy.occupancy.fileCount, language: language),
            shareText: percentText(share(of: occupancy.occupancy.bytes, totalBytes: totalBytes))
        )
    }

    // MARK: - 文案与数字

    /// 一个类别的界面名（PRD §5.1 的「类别」一列）。
    public static func nameText(for category: DataCategory, language: AppLanguage? = nil) -> String {
        L10n.text(nameKey(for: category), language: language)
    }

    /// 「1234 个文件」。
    public static func fileCountText(_ fileCount: Int, language: AppLanguage? = nil) -> String {
        L10n.format(.classificationFileCount, ["\(fileCount)"], language: language)
    }

    /// 占比：按本工具总占用算，总占用为 0 时按 0（不返回 NaN，也不显示 `-`）。
    public static func share(of bytes: Int64, totalBytes: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytes) / Double(totalBytes)
    }

    /// 占比的展示文案：最多两位小数，去掉多余的零（`97.5%`、`0.14%`、`2%`、`0%`）。
    ///
    /// 手工格式化而不用 `NumberFormatter`：后者的输出跟系统语言走（千分位、小数点符号），
    /// 而同一个数字在任何系统下都必须长得一样（与 `ByteSizeFormatter` 同一条纪律）。
    ///
    /// 非零但小于 0.005% 的占比显示成 `<0.01%` 而不是 `0%`——「有，但极小」
    /// 与「一点都没有」是两件事（PRD §9 的诚实展示）。
    public static func percentText(_ share: Double) -> String {
        guard share > 0 else { return "0%" }
        let basisPoints = Int((share * 10_000).rounded())
        guard basisPoints > 0 else { return "<0.01%" }

        let whole = basisPoints / 100
        let fraction = basisPoints % 100
        if fraction == 0 { return "\(whole)%" }
        if fraction % 10 == 0 { return "\(whole).\(fraction / 10)%" }
        return "\(whole).\(String(format: "%02d", fraction))%"
    }

    private static func nameKey(for category: DataCategory) -> L10n.Key {
        switch category {
        case .archivableSession: return .classificationCategoryArchivableSession
        case .cacheAndLog: return .classificationCategoryCacheAndLog
        case .protected: return .classificationCategoryProtected
        case .uncertain: return .classificationCategoryUncertain
        }
    }
}

/// 一台工具的分类明细（界面直接渲染这个值）。
public struct ToolClassificationDetail: Equatable, Identifiable {

    public let toolID: String
    public let displayName: String

    /// 工具根的展示路径（`~/.claude`）。
    public let rootDisplayPath: String

    /// 本工具总占用的展示文案（含规则声明的仅展示根）。
    public let totalSizeText: String
    public let totalFileCountText: String

    /// 四类的明细行，按 PRD §5.1 顺序；本工具下没有数据的类别不出现。
    public let categoryRows: [ClassificationCategoryRow]

    public var id: String { toolID }

    public init(
        toolID: String,
        displayName: String,
        rootDisplayPath: String,
        totalSizeText: String,
        totalFileCountText: String,
        categoryRows: [ClassificationCategoryRow]
    ) {
        self.toolID = toolID
        self.displayName = displayName
        self.rootDisplayPath = rootDisplayPath
        self.totalSizeText = totalSizeText
        self.totalFileCountText = totalFileCountText
        self.categoryRows = categoryRows
    }

    /// 取某一类的明细行；本工具下没有该类数据时返回 `nil`。
    public func row(_ category: DataCategory) -> ClassificationCategoryRow? {
        categoryRows.first { $0.category == category }
    }
}

/// 类别明细里的一行。
public struct ClassificationCategoryRow: Equatable, Identifiable {

    public let category: DataCategory

    /// 类别名（PRD §5.1「类别」一列，L10n）。
    public let nameText: String

    /// 本类占用（`ByteSizeFormatter`）。
    public let sizeText: String

    /// 本类文件数（`1234 个文件`）。
    public let fileCountText: String

    /// 本类占本工具总占用的比例（`97.47%`）。
    public let shareText: String

    public var id: String { category.rawValue }

    public init(
        category: DataCategory,
        nameText: String,
        sizeText: String,
        fileCountText: String,
        shareText: String
    ) {
        self.category = category
        self.nameText = nameText
        self.sizeText = sizeText
        self.fileCountText = fileCountText
        self.shareText = shareText
    }
}
