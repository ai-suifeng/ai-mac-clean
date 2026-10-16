import Foundation

import AIMacCleanDomain

/// 概览页的一屏状态（issue #28；PRD §9）。
///
/// 这是**给界面用的完整快照**：视图不再自己算汇总、排序与辅助功能文案。
/// 与 `DiscoveryPageState` 同一条纪律——整个页面因此可以被一行测试断言。
///
/// ## 重新扫描期间不清空
///
/// `report` 只在**新结果回来时**替换：`isScanning` 为真时它仍是上一轮的结果，
/// 因此界面不会在扫描期间空成一张白纸（验收 6）。第一轮扫描完成前它是 `nil`，
/// 此时界面只显示「正在扫描」，不显示任何 0。
public struct OverviewPageState: Equatable {

    /// 上一轮（或当前）深扫结果。`nil` 表示还没有任何结果。
    public var report: DeepScanReport?

    /// 读到 / 注入的卷容量。`nil` 表示还没读过——界面据此不显示磁盘那一行，
    /// 而不是显示一个「未知」或 0（`VolumeCapacity` 已经把这两种事实分开）。
    public var capacity: VolumeCapacity?

    /// 是否已经完成过至少一轮扫描。空状态据此判定，免得刚打开就闪一句「还没确认工具」。
    public var hasLoaded: Bool

    /// 是否正在后台扫描（issue #21 的纪律：扫描不上主线程）。
    public var isScanning: Bool

    /// 确认存储里的工具条数（去重前）。0 表示该走空状态引导（验收 5）。
    public var confirmedToolCount: Int

    public init(
        report: DeepScanReport? = nil,
        capacity: VolumeCapacity? = nil,
        hasLoaded: Bool = false,
        isScanning: Bool = false,
        confirmedToolCount: Int = 0
    ) {
        self.report = report
        self.capacity = capacity
        self.hasLoaded = hasLoaded
        self.isScanning = isScanning
        self.confirmedToolCount = confirmedToolCount
    }
}

/// 「四类分列」的一行（已格式化成界面文案）。
public struct OverviewCategoryRow: Equatable, Identifiable {

    /// 类别标识（`DataCategory.rawValue`）。
    public let categoryID: String

    /// 类别名（PRD §5.1 的原话）。
    public let title: String

    /// 处理方式（PRD §5.1 的原话）。
    public let handling: String

    /// 「1 MB（2 个文件）」。
    public let occupancyText: String

    public let bytes: Int64
    public let fileCount: Int

    /// 辅助技术读出的一句话。
    public let accessibilityLabel: String

    public var id: String { categoryID }
}

/// 「各工具占用」的一行（已格式化成界面文案）。
public struct OverviewToolRow: Equatable, Identifiable {

    public let toolID: String

    /// 展示名：已知工具取规则里的名字，未知工具是缩写路径。
    public let displayName: String

    /// 工具根的缩写路径（`~/.claude`）。
    public let displayPath: String

    /// 「1.5 MB（3 个文件）」。
    public let occupancyText: String

    public let bytes: Int64
    public let fileCount: Int

    /// 「可归档 1 MB（66.67%）」。
    public let archivableText: String

    /// 「可归档占比极小」——只在收益确实低到必须如实标注时出现（PRD §9）。
    public let negligibleAnnotation: String?

    /// 「其中仅展示（不参与归档）：14 GB」——只有存在仅展示根时出现（PRD §14.1）。
    public let displayOnlyText: String?

    /// 辅助技术读出的一句话。
    public let accessibilityLabel: String

    public var id: String { toolID }
}
