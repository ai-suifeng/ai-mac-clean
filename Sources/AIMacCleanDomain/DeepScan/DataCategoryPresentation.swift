import Foundation

import AIMacCleanRules

/// 分类在界面与说明里的说法（PRD §5.1「四类与处理方式」）。
///
/// 类别本身是规则层的封闭枚举 `DataCategory`：规则文件不能凭空发明新类别，
/// 也不允许把「不确定」降级为「可归档」（issue #11 把关）。这里只负责
/// **怎么称呼它、怎么说明它的处理方式**，不参与任何判定——判定只认规则声明。
extension DataCategory {

    /// 界面上的类别名，逐字取自 PRD §5.1。
    public var displayName: String {
        switch self {
        case .archivableSession: return "可归档会话"
        case .cacheAndLog: return "缓存与日志"
        case .protected: return "受保护"
        case .uncertain: return "不确定"
        }
    }

    /// 处理方式的说明，逐字取自 PRD §5.1「处理」一列。
    ///
    /// 措辞是承诺的一部分：缓存与日志「只展示大小，不动」，受保护「永不触碰」，
    /// 不确定「锁定」。本阶段（M2）四类**都不写盘**，归档是 M3 的事。
    public var handling: String {
        switch self {
        case .archivableSession: return "支持归档"
        case .cacheAndLog: return "只展示大小，不动"
        case .protected: return "永不触碰，仅展示"
        case .uncertain: return "锁定，仅展示大小"
        }
    }

    /// 本阶段能否被归档。
    ///
    /// M2 **一律为假**：归档能力属于 M3。这个属性存在的意义是让界面无从「顺手」
    /// 给一个可点的归档入口——它现在读到的就是「没有哪一类可以归档」。
    public var isArchivableNow: Bool { false }

    /// 四类的固定展示顺序（PRD §5.1 表格顺序），与枚举声明顺序一致。
    public static var displayOrder: [DataCategory] { allCases }
}
