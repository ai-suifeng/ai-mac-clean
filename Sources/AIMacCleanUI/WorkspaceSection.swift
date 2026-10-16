import Foundation

/// 主窗口侧边栏分栏（PRD §9）。
///
/// 本阶段（issue #16）只有「发现与确认」是真实页面，其余分栏是占位，
/// 且占位文案明确写着「本阶段还没有归档能力」——不给用户任何做不出来的承诺。
public enum WorkspaceSection: String, CaseIterable, Identifiable, Sendable {
    case overview
    case discovery
    case archive
    case archived
    case settings

    public var id: String { rawValue }

    /// 中文标题。UI 文案以中文落地（spec #7：本地化结构先建立，文案可先单语言），
    /// 但取文案统一走 `L10n`，英文目录下会给出英文标题（User Story 40）。
    public var title: String {
        L10n.text(titleKey)
    }

    /// 占位阶段该分栏的一句话说明，同时作为辅助功能读出的名称。
    public var accessibilityLabel: String {
        L10n.text(accessibilityKey)
    }

    /// 占位图标名，等后续票接入真实内容时替换。
    public var symbolName: String {
        switch self {
        case .overview: return "chart.bar"
        case .discovery: return "magnifyingglass"
        case .archive: return "archivebox"
        case .archived: return "tray.full"
        case .settings: return "gearshape"
        }
    }

    /// 该分栏在本票中尚未实现的内容说明，直接展示在空态里。
    public var placeholderMessage: String {
        L10n.text(placeholderKey)
    }

    /// 本阶段是不是真实页面。
    ///
    /// 发现与确认页是 issue #16，概览页是 issue #28；其余三个分栏仍是占位。
    public var isImplemented: Bool {
        switch self {
        case .overview, .discovery: return true
        case .archive, .archived, .settings: return false
        }
    }

    private var titleKey: L10n.Key {
        switch self {
        case .overview: return .sidebarSectionOverview
        case .discovery: return .sidebarSectionDiscovery
        case .archive: return .sidebarSectionArchive
        case .archived: return .sidebarSectionArchived
        case .settings: return .sidebarSectionSettings
        }
    }

    private var accessibilityKey: L10n.Key {
        switch self {
        case .overview: return .sidebarAccessibilityOverview
        case .discovery: return .sidebarAccessibilityDiscovery
        case .archive: return .sidebarAccessibilityArchive
        case .archived: return .sidebarAccessibilityArchived
        case .settings: return .sidebarAccessibilitySettings
        }
    }

    private var placeholderKey: L10n.Key {
        switch self {
        case .discovery:
            // 发现与确认页已经是真实页面，占位文案不会被展示到。
            return .discoveryStageNote
        case .overview:
            // 概览页（issue #28）已经是真实页面：这里给当前阶段的实话，
            // 而不是「深扫落地后会展示可归档预计释放空间」那种对 M2 的预告
            // （§9 的压缩节省 / 搬迁腾出分列属 M3）。
            return .overviewStageNote
        case .archive: return .placeholderArchive
        case .archived: return .placeholderArchived
        case .settings: return .placeholderSettings
        }
    }
}

/// 主窗口的分栏选择状态。
public struct WorkspaceShellModel: Equatable, Sendable {
    /// 启动时选中的分栏。
    ///
    /// 仍然落在「发现与确认」。概览页（issue #28）现在也是真实页面，但**先确认工具**
    /// 才有占用可看，默认停在那份数据的来源页；概览页的空状态会把用户指过来。
    /// 文档没有规定默认落地页（PRD §9 只定了分栏集合），因此这里取最小改动，
    /// 不顺手改产品的第一屏。
    public static let defaultSelection: WorkspaceSection = .discovery

    /// 当前选中的分栏。
    public var selection: WorkspaceSection

    public init(selection: WorkspaceSection = WorkspaceShellModel.defaultSelection) {
        self.selection = selection
    }
}
