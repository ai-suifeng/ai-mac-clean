import Foundation

/// 界面文案的语言（PRD §9「支持浅色/深色模式，中文/英文」；User Stories 39、40）。
///
/// M1 只落地中文与英文两套文案，但语言是**枚举**而不是隐式的系统语言：
/// 这样设置页将来加语言开关时不必改动取文案的调用点。
public enum AppLanguage: String, CaseIterable, Sendable {
    /// 简体中文（PRD §9 的界面语言；本阶段的基准文案）。
    case simplifiedChinese
    /// English。
    case english

    /// 资源目录里对应的 `.lproj` 名。
    var localizationDirectoryName: String {
        switch self {
        case .simplifiedChinese: return "zh-Hans"
        case .english: return "en"
        }
    }
}

/// 本地化文案入口（issue #16；spec #7「本阶段建立本地化结构，文案可先以单语言落地」）。
///
/// 约定三条：
/// 1. **界面文案不散落在视图里**：视图只引用 `L10n.Key`，文案集中在资源目录的
///    `zh-Hans.lproj` / `en.lproj` 两份 `Localizable.strings`。
/// 2. **取不到就落到中文**：缺词时显示中文，而不是把 key 本身甩给用户看。
/// 3. **格式串带参数**：需要拼接的内容（如「路径（原因）」）走 `L10n.format`，
///    参数顺序由资源决定，不在调用点拼句子。
public enum L10n {

    /// 资源表名。
    public static let tableName = "Localizable"

    /// 全部文案 key。登记在这里的 key 必须在两套目录里都存在——
    /// `LocalizationCatalogTests` 会核对目录与枚举的一致性。
    public enum Key: String, CaseIterable, Sendable {
        // 应用与分栏
        case appTitle = "app.title"
        case sidebarSectionOverview = "sidebar.section.overview"
        case sidebarSectionDiscovery = "sidebar.section.discovery"
        case sidebarSectionArchive = "sidebar.section.archive"
        case sidebarSectionArchived = "sidebar.section.archived"
        case sidebarSectionSettings = "sidebar.section.settings"

        case sidebarAccessibilityOverview = "sidebar.accessibility.overview"
        case sidebarAccessibilityDiscovery = "sidebar.accessibility.discovery"
        case sidebarAccessibilityArchive = "sidebar.accessibility.archive"
        case sidebarAccessibilityArchived = "sidebar.accessibility.archived"
        case sidebarAccessibilitySettings = "sidebar.accessibility.settings"

        // 概览占位文案随 issue #28 下线：这一页已经是真实页面，
        // 它取的说明改走 `overview.stage.note`（当前阶段的实话）。
        case placeholderArchive = "placeholder.archive"
        case placeholderArchived = "placeholder.archived"
        case placeholderSettings = "placeholder.settings"

        // 概览页（issue #28）
        case overviewPageTitle = "overview.page.title"
        case overviewStageNote = "overview.stage.note"
        case overviewScanning = "overview.status.scanning"
        case overviewReload = "overview.action.reload"
        case overviewEmptyNoTools = "overview.empty.noTools"
        case overviewTotalValue = "overview.total.value"
        case overviewArchivableValue = "overview.archivable.value"
        case overviewSectionCategories = "overview.section.categories"
        case overviewSectionTools = "overview.section.tools"
        case overviewOccupancyValue = "overview.occupancy.value"
        case overviewToolArchivable = "overview.tool.archivable"
        case overviewToolNegligible = "overview.tool.negligible"
        case overviewToolDisplayOnly = "overview.tool.displayOnly"
        case overviewDiskFree = "overview.disk.free"
        case overviewDiskUnknownUnreadable = "overview.disk.unknown.unreadable"
        case overviewDiskUnknownNotReported = "overview.disk.unknown.notReported"
        case overviewArchiveAction = "overview.action.archive"
        case overviewArchiveDisabledReason = "overview.archive.disabledReason"
        case overviewAccessibilityTotal = "overview.accessibility.total"
        case overviewAccessibilityCategory = "overview.accessibility.category"
        case overviewAccessibilityTool = "overview.accessibility.tool"

        // 发现与确认页
        case discoveryPageTitle = "discovery.page.title"
        case discoveryScanning = "discovery.status.scanning"
        case discoveryReload = "discovery.action.reload"
        case discoveryGroupHigh = "discovery.group.high"
        case discoveryGroupMedium = "discovery.group.medium"
        case discoveryGroupLow = "discovery.group.low"
        case discoveryGroupExpanded = "discovery.group.expanded"
        case discoveryGroupCollapsed = "discovery.group.collapsed"
        case discoveryConfidenceHigh = "discovery.confidence.high"
        case discoveryConfidenceMedium = "discovery.confidence.medium"
        case discoveryConfidenceLow = "discovery.confidence.low"
        case discoverySuspiciousBadge = "discovery.badge.suspicious"
        case discoveryActionConfirm = "discovery.action.confirm"
        case discoveryActionIgnore = "discovery.action.ignore"
        case discoveryActionForget = "discovery.action.forget"
        case discoveryActionRestore = "discovery.action.restore"
        case discoverySectionPending = "discovery.section.pending"
        case discoverySectionConfirmed = "discovery.section.confirmed"
        case discoverySectionIgnored = "discovery.section.ignored"
        case discoveryEmptyPending = "discovery.empty.pending"
        case discoveryEmptyConfirmed = "discovery.empty.confirmed"
        case discoveryEmptyIgnored = "discovery.empty.ignored"
        case discoveryStageNote = "discovery.stage.note"

        // 信号与降权
        case discoverySignalStructural = "discovery.signal.structural"
        case discoverySignalName = "discovery.signal.name"
        case discoverySignalApplication = "discovery.signal.application"
        case discoverySignalCommand = "discovery.signal.command"
        case discoverySignalContentFeature = "discovery.signal.contentFeature"
        case discoveryDemotionNegativeName = "discovery.demotion.negativeName"
        case discoveryDemotionMissingFingerprint = "discovery.demotion.missingFingerprint"
        case discoveryProtectionNote = "discovery.protection.note"

        // 辅助功能（User Story 42）
        case candidateAccessibility = "candidate.accessibility"
        case confirmedToolAccessibility = "candidate.accessibility.confirmed"
        case ignoredCandidateAccessibility = "candidate.accessibility.ignored"

        // 权限与加载失败（PRD §4.4、User Story 37）
        case discoveryPermissionTitle = "discovery.permission.title"
        case discoveryPermissionRow = "discovery.permission.row"
        case discoveryPermissionFootnote = "discovery.permission.footnote"
        case discoveryIssueNoRules = "discovery.issue.noRules"
        case discoveryIssueRulesRejected = "discovery.issue.rulesRejected"
        case discoveryIssueHintsUnavailable = "discovery.issue.hintsUnavailable"
        case discoveryIssueStoreUnreadable = "discovery.issue.storeUnreadable"
        case discoveryIssueActionFailed = "discovery.issue.actionFailed"

        // 工具分类明细（issue #27；PRD §5.1 四类与处理方式、§9）
        case classificationPageTitle = "classification.page.title"
        case classificationStageNote = "classification.page.stageNote"
        case classificationScanning = "classification.status.scanning"
        case classificationReload = "classification.action.reload"
        case classificationEmpty = "classification.empty"
        case classificationIssueNoRules = "classification.issue.noRules"
        case classificationIssueRulesRejected = "classification.issue.rulesRejected"
        case classificationFileCount = "classification.fileCount"
        case classificationCategoryArchivableSession = "classification.category.archivableSession"
        case classificationCategoryCacheAndLog = "classification.category.cacheAndLog"
        case classificationCategoryProtected = "classification.category.protected"
        case classificationCategoryUncertain = "classification.category.uncertain"
        case classificationHandlingArchivableSession = "classification.handling.archivableSession"
        case classificationHandlingArchivableSessionStage = "classification.handling.archivableSession.stage"
        case classificationHandlingCacheAndLog = "classification.handling.cacheAndLog"
        case classificationHandlingProtected = "classification.handling.protected"
        case classificationHandlingUncertain = "classification.handling.uncertain"
        case classificationArchivableShareLabel = "classification.archivableShare.label"
        case classificationArchivableShareTiny = "classification.archivableShare.tiny"
        case classificationSummaryTitle = "classification.summary.title"
        case classificationSummaryRow = "classification.summary.row"
        case classificationSummaryUndeclared = "classification.summary.undeclared"
        case classificationSummaryProtectedReason = "classification.summary.protectedReason"
        case classificationSummaryPattern = "classification.summary.pattern"
        case classificationSummaryAncestor = "classification.summary.ancestor"
        case classificationSummaryMore = "classification.summary.more"
        case classificationToolAccessibility = "classification.tool.accessibility"
        case classificationToolAccessibilityValue = "classification.tool.accessibilityValue"
        case classificationCategoryAccessibility = "classification.category.accessibility"
        case classificationCategoryShare = "classification.category.share"
        case classificationRootToolRoot = "classification.root.toolRoot"
        case classificationRootDisplayOnly = "classification.root.displayOnly"
        case classificationRootDisplayOnlyNote = "classification.root.displayOnly.note"
        case classificationRootAccessibility = "classification.root.accessibility"
        case classificationUnreadableTitle = "classification.unreadable.title"
        case classificationUnreadableRow = "classification.unreadable.row"
        case classificationUnreadableKindDirectory = "classification.unreadable.kind.directory"
        case classificationUnreadableKindItem = "classification.unreadable.kind.item"
        case classificationUnreadableNoReason = "classification.unreadable.noReason"
        case classificationUnreadableFootnote = "classification.unreadable.footnote"
    }

    /// 按当前系统语言取文案，取不到时落到中文。
    public static func text(_ key: Key) -> String {
        text(key, language: nil)
    }

    /// 按指定语言取文案。
    ///
    /// - Parameter language: `nil` 表示不指定语言，取**基准语言**（简体中文，见
    ///   `Package.swift` 的 `defaultLocalization`）；界面要显示英文时必须显式传
    ///   `.english`（页面模型都接一个 `language` 参数，生产接线负责传值）。
    ///   无论哪种情况，取不到时都回落到简体中文，不把 key 显示给用户。
    public static func text(_ key: Key, language: AppLanguage?) -> String {
        if let language, let bundle = catalogBundle(for: language) {
            let value = bundle.localizedString(forKey: key.rawValue, value: missingSentinel, table: tableName)
            if value != missingSentinel { return value }
        }
        return catalogText(key, language: .simplifiedChinese) ?? key.rawValue
    }

    /// 带参数的文案。参数顺序由资源里的格式串决定。
    public static func format(_ key: Key, _ arguments: [CVarArg], language: AppLanguage? = nil) -> String {
        String(format: text(key, language: language), arguments: arguments)
    }

    /// 一套语言目录里的全部 key（供测试核对目录结构）。
    public static func catalogKeys(language: AppLanguage) -> [String] {
        guard let bundle = catalogBundle(for: language) else { return [] }
        return localizedStrings(in: bundle).keys.sorted()
    }

    // MARK: - 内部

    /// `localizedString` 在缺词时原样返回 key，因此需要一个不会撞上真实文案的哨兵。
    private static let missingSentinel = "\u{0}amc-missing"

    private static func catalogText(_ key: Key, language: AppLanguage) -> String? {
        guard let bundle = catalogBundle(for: language) else { return nil }
        let value = bundle.localizedString(forKey: key.rawValue, value: missingSentinel, table: tableName)
        return value == missingSentinel ? nil : value
    }

    /// 语言目录对应的 bundle。资源缺失时返回 `nil`，由调用方决定回落。
    ///
    /// 目录名按**忽略大小写**匹配：SwiftPM 处理资源时会把 `zh-Hans.lproj` 落成
    /// `zh-hans.lproj`，而 .app 打包工具通常保留原样——两种都得能取到。
    private static func catalogBundle(for language: AppLanguage) -> Bundle? {
        let wanted = language.localizationDirectoryName.lowercased()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: Bundle.module.resourceURL ?? Bundle.module.bundleURL,
            includingPropertiesForKeys: nil
        ) else { return nil }

        for url in contents
            where url.pathExtension.lowercased() == "lproj"
                && url.deletingPathExtension().lastPathComponent.lowercased() == wanted {
            return Bundle(url: url)
        }
        return nil
    }

    private static func localizedStrings(in bundle: Bundle) -> [String: String] {
        guard let url = bundle.url(forResource: tableName, withExtension: "strings"),
              let dictionary = NSDictionary(contentsOf: url) as? [String: String]
        else { return [:] }
        return dictionary
    }
}
