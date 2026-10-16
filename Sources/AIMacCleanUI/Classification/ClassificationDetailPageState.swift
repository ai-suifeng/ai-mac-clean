import Foundation

import AIMacCleanDomain

/// 分类明细页的一屏状态（issue #27）。
///
/// 这是**给界面用的完整快照**：视图不再自己算顺序、拼文案、读规则或确认存储。
/// 整个页面因此可以被一行测试断言。
public struct ClassificationDetailPageState: Equatable {

    /// 每台已确认工具一份分类明细，顺序沿用深扫报告（按工具标识排序）。
    public var details: [ToolClassificationDetail]

    /// 这次运行里已知的问题（规则没载入、规则全被拒绝）。
    public var issues: [DeepScanIssue]

    /// 是否已经跑过一次深扫。
    public var hasLoaded: Bool

    /// 是否正在扫描。扫描在后台跑，界面据此禁用「重新扫描」并给出进度提示。
    public var isScanning: Bool

    public init(
        details: [ToolClassificationDetail] = [],
        issues: [DeepScanIssue] = [],
        hasLoaded: Bool = false,
        isScanning: Bool = false
    ) {
        self.details = details
        self.issues = issues
        self.hasLoaded = hasLoaded
        self.isScanning = isScanning
    }

    /// 扫描完成、没有明细、也没有问题：用户还没确认过任何工具。
    ///
    /// 与「规则出问题导致的空结果」分开：那两种情况要说的话完全不同，
    /// 混在一起就会对着一台装了工具的机器说「还没有确认过任何工具」。
    public var isEmpty: Bool { hasLoaded && details.isEmpty && issues.isEmpty }
}
