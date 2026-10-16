import Foundation

import AIMacCleanRules

/// 四类在**领域层的名字**。
///
/// 分类判定的唯一出处是规则层（`AIMacCleanRules.DataCategory`，规则文件不能凭空发明
/// 新类别，issue #11 把关）；但界面层只依赖 Domain（`DomainLayer` 的边界约定），
/// 而它要展示的正是四类占用。这里因此把类型名接到领域层：界面可以引用
/// `DataCategory`，不必 import Rules，也不会顺手去碰规则引擎。
public typealias DataCategory = AIMacCleanRules.DataCategory

/// 分类在领域层的**结构与顺序**（PRD §5.1「四类与处理方式」）。
///
/// 类别本身是规则层的封闭枚举 `DataCategory`：规则文件不能凭空发明新类别，
/// 也不允许把「不确定」降级为「可归档」（issue #11 把关）。
///
/// 这里**不携带任何面向用户的文案**：类别名与处理方式在界面层的
/// `CategoryCopy` 之后由本地化目录（`L10n` 的 `classification.category.*` /
/// `classification.handling.*`）给出，两页共用同一份。领域层只负责
/// 「四类有哪些、按什么顺序摆、本阶段能不能归档」。
extension DataCategory {

    /// 本阶段能否被归档。
    ///
    /// M2 **一律为假**：归档能力属于 M3。这个属性存在的意义是让界面无从「顺手」
    /// 给一个可点的归档入口——它现在读到的就是「没有哪一类可以归档」。
    public var isArchivableNow: Bool { false }

    /// 四类的固定展示顺序：PRD §5.1 表格的行顺序
    /// （可归档会话 / 缓存与日志 / 受保护 / 不确定）。
    ///
    /// **显式写出来，不写成 `allCases`**：界面的行顺序是产品口径，不是枚举声明顺序的
    /// 副产物。将来枚举增删或重排时，这一行顺序不该跟着动（`DataCategoryPresentationTests`
    /// 把它钉在 PRD §5.1 的序列上）。
    public static let displayOrder: [DataCategory] = [
        .archivableSession,
        .cacheAndLog,
        .protected,
        .uncertain,
    ]
}
