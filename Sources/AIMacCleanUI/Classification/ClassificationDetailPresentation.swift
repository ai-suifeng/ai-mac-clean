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

        // 可归档占比：这是 PRD §9 要求如实给出的那个数（§14.1 的 Claude Code 只有 0.14%）。
        // 占比极小时给一句标注——但**不**用大字号、**不**换算成「能腾出多少」，
        // 更不出现任何压缩率估算（那是 M3）。
        let archivableShare = share(of: report.archivableOccupancy.bytes, totalBytes: totalBytes)
        let isTinyShare = totalBytes > 0 && archivableShare < tinyArchivableShareThreshold

        return ToolClassificationDetail(
            toolID: report.toolID,
            displayName: report.displayName,
            rootDisplayPath: ToolRootDisplay.abbreviated(report.toolRootPath, homeDirectory: homeDirectory),
            totalSizeText: report.occupancy.sizeText,
            totalFileCountText: fileCountText(report.occupancy.fileCount, language: language),
            categoryRows: rows,
            rootRows: report.roots.map { rootRow(for: $0, homeDirectory: homeDirectory, language: language) },
            unreadableRows: report.unreadable.map { unreadableRow(for: $0, language: language) },
            archivableShareText: percentText(archivableShare),
            isArchivableShareTiny: isTinyShare,
            tinyArchivableShareNotice: isTinyShare
                ? L10n.text(.classificationArchivableShareTiny, language: language)
                : nil,
            accessibilityLabel: L10n.format(
                .classificationToolAccessibility,
                [report.displayName],
                language: language
            ),
            accessibilityValue: L10n.format(
                .classificationToolAccessibilityValue,
                [report.occupancy.sizeText, percentText(archivableShare)],
                language: language
            )
        )
    }

    // MARK: - 根

    /// 一个根的一行（主工具根 / 规则声明的仅展示根）。
    ///
    /// 一个工具的占用可能来自多个根（issue #31）：Cursor 是 `~/.cursor` 2.1G +
    /// `~/Library/Application Support/Cursor` 14G。合成一个数会让用户以为 Cursor 只占 2.1G
    /// （PRD §14.1），因此两个根分开列。
    private static func rootRow(
        for root: ToolRootOccupancy,
        homeDirectory: String,
        language: AppLanguage?
    ) -> ClassificationRootRow {
        let roleText: String = switch root.role {
        case .toolRoot: L10n.text(.classificationRootToolRoot, language: language)
        case .displayOnly: L10n.text(.classificationRootDisplayOnly, language: language)
        }
        let displayPath = ToolRootDisplay.abbreviated(root.path, homeDirectory: homeDirectory)
        let sizeText = root.occupancy.sizeText
        return ClassificationRootRow(
            roleText: roleText,
            displayPath: displayPath,
            sizeText: sizeText,
            fileCountText: fileCountText(root.occupancy.fileCount, language: language),
            noteText: root.role == .displayOnly
                ? L10n.text(.classificationRootDisplayOnlyNote, language: language)
                : nil,
            accessibilityLabel: L10n.format(
                .classificationRootAccessibility,
                [roleText, displayPath, sizeText],
                language: language
            )
        )
    }

    // MARK: - 读不到的位置（PRD §4.4）

    /// 一条读不到的位置。
    ///
    /// 深扫**不会**因为读不到而失败（PRD §4.4 按目录粒度隔离）：界面的职责是把这些位置
    /// 如实列出来并说明，而不是让它们从总数里悄悄消失。
    private static func unreadableRow(
        for entry: UnreadableEntry,
        language: AppLanguage?
    ) -> ClassificationUnreadableRow {
        let kindText: String = switch entry.kind {
        case .directory: L10n.text(.classificationUnreadableKindDirectory, language: language)
        case .item: L10n.text(.classificationUnreadableKindItem, language: language)
        }
        let reasonText = entry.reason ?? L10n.text(.classificationUnreadableNoReason, language: language)
        return ClassificationUnreadableRow(
            relativePath: entry.relativePath,
            kindText: kindText,
            reasonText: reasonText,
            text: L10n.format(
                .classificationUnreadableRow,
                [entry.relativePath, kindText, reasonText],
                language: language
            )
        )
    }

    // MARK: - 一行

    private static func row(
        for occupancy: CategoryOccupancy,
        totalBytes: Int64,
        language: AppLanguage?
    ) -> ClassificationCategoryRow {
        let summaries = summaryRows(for: occupancy, language: language)
        let name = nameText(for: occupancy.category, language: language)
        let handling = handlingText(for: occupancy.category, language: language)
        let sizeText = occupancy.occupancy.sizeText
        let shareText = percentText(share(of: occupancy.occupancy.bytes, totalBytes: totalBytes))
        return ClassificationCategoryRow(
            category: occupancy.category,
            nameText: name,
            handlingText: handling,
            noteText: occupancy.category == .archivableSession
                ? L10n.text(.classificationHandlingArchivableSessionStage, language: language)
                : nil,
            isArchivableNow: occupancy.category.isArchivableNow,
            sizeText: sizeText,
            fileCountText: fileCountText(occupancy.occupancy.fileCount, language: language),
            shareText: shareText,
            summaries: summaries.rows,
            hiddenSummaryCount: summaries.hidden,
            accessibilityLabel: L10n.format(
                .classificationCategoryAccessibility,
                [name, sizeText, shareText, handling],
                language: language
            )
        )
    }

    // MARK: - 子路径明细

    /// 一个类别按子路径的明细：字节数从大到小，只列前 `maxSummariesPerCategory` 条。
    ///
    /// 这里再排一次序（领域层已经保证降序），因为**界面的顺序是界面自己的承诺**：
    /// 「受保护的大头排在最上面」不依赖上游有没有按约定给。
    ///
    /// 被截掉的那些只报数量（`另有 2 项`），不静默丢弃——用户要知道这里不是全部。
    private static func summaryRows(
        for occupancy: CategoryOccupancy,
        language: AppLanguage?
    ) -> (rows: [ClassificationSummaryRow], hidden: Int) {
        let sorted = occupancy.summaries.sorted { lhs, rhs in
            if lhs.occupancy.bytes != rhs.occupancy.bytes { return lhs.occupancy.bytes > rhs.occupancy.bytes }
            return lhs.subpath < rhs.subpath
        }
        let rows = sorted.prefix(maxSummariesPerCategory).map { summary -> ClassificationSummaryRow in
            let fileCount = fileCountText(summary.occupancy.fileCount, language: language)
            return ClassificationSummaryRow(
                subpath: summary.subpath,
                sizeText: summary.occupancy.sizeText,
                fileCountText: fileCount,
                attributionText: attributionText(for: summary, language: language),
                text: L10n.format(
                    .classificationSummaryRow,
                    [summary.subpath, summary.occupancy.sizeText, fileCount],
                    language: language
                )
            )
        }
        return (rows, max(0, sorted.count - rows.count))
    }

    /// 一条子路径「为什么是这一类」：内置受保护清单 / 规则声明 / 由规则覆盖 / 规则未声明。
    ///
    /// 内置清单与规则声明必须分开说：规则可以被用户改，内置清单不能（PRD §8.1）。
    public static func attributionText(for summary: CategorySummary, language: AppLanguage? = nil) -> String? {
        if let reason = summary.protectionReason {
            return L10n.format(.classificationSummaryProtectedReason, [reason], language: language)
        }
        switch summary.provenance {
        case .undeclared:
            return L10n.text(.classificationSummaryUndeclared, language: language)
        case let .declaredPath(path):
            return L10n.format(.classificationSummaryPattern, [summary.pattern ?? path], language: language)
        case let .declaredAncestor(path):
            return L10n.format(.classificationSummaryAncestor, [summary.pattern ?? path], language: language)
        }
    }

    // MARK: - 文案与数字

    /// 一个类别的界面名（PRD §5.1 的「类别」一列）。
    public static func nameText(for category: DataCategory, language: AppLanguage? = nil) -> String {
        L10n.text(nameKey(for: category), language: language)
    }

    /// 一个类别的处理方式（PRD §5.1 的「处理」一列，逐字）。
    ///
    /// 这三句是**承诺**：缓存与日志「只展示大小，不动」、受保护「永不触碰」、
    /// 不确定「锁定」。界面不得改写、不得省略（诚实展示）。
    public static func handlingText(for category: DataCategory, language: AppLanguage? = nil) -> String {
        L10n.text(handlingKey(for: category), language: language)
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

    private static func handlingKey(for category: DataCategory) -> L10n.Key {
        switch category {
        case .archivableSession: return .classificationHandlingArchivableSession
        case .cacheAndLog: return .classificationHandlingCacheAndLog
        case .protected: return .classificationHandlingProtected
        case .uncertain: return .classificationHandlingUncertain
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

    /// 本工具的占用由哪几个根贡献（主工具根在前，规则声明的仅展示根在后）。
    public let rootRows: [ClassificationRootRow]

    /// 本次扫描里读不到的位置，逐条列出（PRD §4.4）。
    public let unreadableRows: [ClassificationUnreadableRow]

    /// 可归档占比的展示文案（`0.14%`）：可归档字节 ÷ 本工具总占用。
    public let archivableShareText: String

    /// 可归档占比是否低于「极小」阈值（PRD §9）。
    public let isArchivableShareTiny: Bool

    /// 可归档占比极小时的如实标注；正常占比时为 `nil`（界面上不出现任何相关话术）。
    public let tinyArchivableShareNotice: String?

    /// 辅助技术读到的名称：`Claude Code 的占用明细`。
    public let accessibilityLabel: String

    /// 辅助技术读到的值：`合计 277 MB，可归档占比 0.14%`。
    public let accessibilityValue: String

    public var id: String { toolID }

    public init(
        toolID: String,
        displayName: String,
        rootDisplayPath: String,
        totalSizeText: String,
        totalFileCountText: String,
        categoryRows: [ClassificationCategoryRow],
        rootRows: [ClassificationRootRow],
        unreadableRows: [ClassificationUnreadableRow],
        archivableShareText: String,
        isArchivableShareTiny: Bool,
        tinyArchivableShareNotice: String?,
        accessibilityLabel: String,
        accessibilityValue: String
    ) {
        self.toolID = toolID
        self.displayName = displayName
        self.rootDisplayPath = rootDisplayPath
        self.totalSizeText = totalSizeText
        self.totalFileCountText = totalFileCountText
        self.categoryRows = categoryRows
        self.rootRows = rootRows
        self.unreadableRows = unreadableRows
        self.archivableShareText = archivableShareText
        self.isArchivableShareTiny = isArchivableShareTiny
        self.tinyArchivableShareNotice = tinyArchivableShareNotice
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
    }

    /// 取某一类的明细行；本工具下没有该类数据时返回 `nil`。
    public func row(_ category: DataCategory) -> ClassificationCategoryRow? {
        categoryRows.first { $0.category == category }
    }

    /// 要不要单独把根拆开列：只有一个根时不拆（总数已经说明问题）；
    /// 有仅展示根时必须拆，否则用户会以为工具只占主根那点（PRD §14.1）。
    public var showsRootBreakdown: Bool { rootRows.count > 1 }

    /// 有没有读不到的位置（没有时界面上不出现任何权限相关的话术，PRD §4.4）。
    public var hasUnreadableEntries: Bool { !unreadableRows.isEmpty }
}

/// 类别明细里的一行。
public struct ClassificationCategoryRow: Equatable, Identifiable {

    public let category: DataCategory

    /// 类别名（PRD §5.1「类别」一列，L10n）。
    public let nameText: String

    /// 处理方式（PRD §5.1「处理」一列，L10n，逐字）。
    ///
    /// 不可归档的三类靠它把承诺说清楚：只展示 / 永不触碰 / 锁定。
    public let handlingText: String

    /// 处理方式之后还要补的一句（目前只有可归档会话需要：归档能力是 M3）。
    public let noteText: String?

    /// 本阶段（M2）这一类能不能被归档。四类一律为假——归档是 M3。
    public let isArchivableNow: Bool

    /// 本类占用（`ByteSizeFormatter`）。
    public let sizeText: String

    /// 本类文件数（`1234 个文件`）。
    public let fileCountText: String

    /// 本类占本工具总占用的比例（`97.47%`）。
    public let shareText: String

    /// 本类按子路径的明细，字节数从大到小（最多 `ClassificationDetailPresenter.maxSummariesPerCategory` 条）。
    public let summaries: [ClassificationSummaryRow]

    /// 被截掉的明细条数：界面上写成「另有 N 项」，不静默丢掉。
    public let hiddenSummaryCount: Int

    /// 辅助技术读到的名称：`受保护，270 MB，占 97.47%，永不触碰，仅展示`。
    public let accessibilityLabel: String

    public var id: String { category.rawValue }

    public init(
        category: DataCategory,
        nameText: String,
        handlingText: String,
        noteText: String? = nil,
        isArchivableNow: Bool,
        sizeText: String,
        fileCountText: String,
        shareText: String,
        summaries: [ClassificationSummaryRow] = [],
        hiddenSummaryCount: Int = 0,
        accessibilityLabel: String
    ) {
        self.category = category
        self.nameText = nameText
        self.handlingText = handlingText
        self.noteText = noteText
        self.isArchivableNow = isArchivableNow
        self.sizeText = sizeText
        self.fileCountText = fileCountText
        self.shareText = shareText
        self.summaries = summaries
        self.hiddenSummaryCount = hiddenSummaryCount
        self.accessibilityLabel = accessibilityLabel
    }
}

/// 一条子路径明细：类别内「谁占了大头」。
///
/// 受保护的 `plugins/` 247M、`skills/` 23M 这类大头就出现在这里（PRD §14.1）。
public struct ClassificationSummaryRow: Equatable, Identifiable {

    /// 相对所属根的子路径（`plugins`、`shell-snapshots`）。
    public let subpath: String

    /// 该子路径的占用。
    public let sizeText: String

    /// 该子路径的文件数。
    public let fileCountText: String

    /// 「为什么是这一类」：内置受保护清单 / 规则声明 / 由规则覆盖 / 规则未声明。
    public let attributionText: String?

    /// 渲染用的整行文字：`plugins（247 MB，1200 个文件）`。
    public let text: String

    public var id: String { subpath }

    public init(
        subpath: String,
        sizeText: String,
        fileCountText: String,
        attributionText: String?,
        text: String
    ) {
        self.subpath = subpath
        self.sizeText = sizeText
        self.fileCountText = fileCountText
        self.attributionText = attributionText
        self.text = text
    }
}

/// 一个根的一行：主工具根（归档范围的起点）或规则声明的仅展示根。
public struct ClassificationRootRow: Equatable, Identifiable {

    /// 根的角色名（`工具根` / `仅展示根`）。
    public let roleText: String

    /// 根的展示路径（`~/.cursor`）。
    public let displayPath: String

    public let sizeText: String
    public let fileCountText: String

    /// 仅展示根要额外说清纪律：`只计算占用，绝不归档也绝不移除`。主根为 `nil`。
    public let noteText: String?

    public let accessibilityLabel: String

    public var id: String { displayPath }

    public init(
        roleText: String,
        displayPath: String,
        sizeText: String,
        fileCountText: String,
        noteText: String?,
        accessibilityLabel: String
    ) {
        self.roleText = roleText
        self.displayPath = displayPath
        self.sizeText = sizeText
        self.fileCountText = fileCountText
        self.noteText = noteText
        self.accessibilityLabel = accessibilityLabel
    }
}

/// 一条读不到的位置（PRD §4.4）。
public struct ClassificationUnreadableRow: Equatable, Identifiable {

    /// 相对所属根的路径。
    public let relativePath: String

    /// 读不到的对象种类（`目录` / `条目（字节数按 0 计）`）。
    public let kindText: String

    /// 文件系统给出的原因；读不到时为「未能取到原因」。
    public let reasonText: String

    /// 渲染用的整行文字：`projects/private 目录：EPERM`。
    public let text: String

    public var id: String { relativePath + "|" + kindText }

    /// 辅助技术读到的就是这一行——位置与原因缺一不可。
    public var accessibilityLabel: String { text }

    public init(relativePath: String, kindText: String, reasonText: String, text: String) {
        self.relativePath = relativePath
        self.kindText = kindText
        self.reasonText = reasonText
        self.text = text
    }
}
