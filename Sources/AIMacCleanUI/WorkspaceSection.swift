import Foundation

/// 主窗口侧边栏分栏（PRD §9）。
///
/// 本票（#8）只提供空的分栏占位，各分栏内容由后续票填入。
public enum WorkspaceSection: String, CaseIterable, Identifiable, Sendable {
    case overview
    case discovery
    case archive
    case archived
    case settings

    public var id: String { rawValue }

    /// 中文标题。UI 文案以中文落地（spec #7：本地化结构先建立，文案可先单语言）。
    public var title: String {
        switch self {
        case .overview: return "概览"
        case .discovery: return "发现与确认"
        case .archive: return "归档"
        case .archived: return "已归档"
        case .settings: return "设置"
        }
    }

    /// 占位阶段该分栏的一句话说明，同时作为辅助功能读出的名称。
    public var accessibilityLabel: String {
        switch self {
        case .overview:
            return "概览：总占用与可归档预计释放空间"
        case .discovery:
            return "发现与确认：候选列表与置信度标识"
        case .archive:
            return "归档：范围选择、预览与结果汇总"
        case .archived:
            return "已归档：浏览、搜索与还原"
        case .settings:
            return "设置：归档位置与已确认工具管理"
        }
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
        switch self {
        case .overview:
            return "概览将在深扫落地后展示总占用与可归档预计释放空间。"
        case .discovery:
            return "发现与确认将在结构指纹浅扫落地后展示候选列表。"
        case .archive:
            return "归档将在自校验归档包落地后可用。"
        case .archived:
            return "已归档将在还原能力落地后可用。"
        case .settings:
            return "设置将在归档位置与已确认工具管理落地后可用。"
        }
    }
}

/// 主窗口的分栏选择状态。
public struct WorkspaceShellModel: Equatable, Sendable {
    /// 启动时选中的分栏。
    public static let defaultSelection: WorkspaceSection = .overview

    /// 当前选中的分栏。
    public var selection: WorkspaceSection

    public init(selection: WorkspaceSection = WorkspaceShellModel.defaultSelection) {
        self.selection = selection
    }
}
