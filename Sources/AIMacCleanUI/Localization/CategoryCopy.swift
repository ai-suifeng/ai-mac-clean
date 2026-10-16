import Foundation

import AIMacCleanDomain

/// 四类的**界面名称与处理方式**（PRD §5.1 的「类别」与「处理」两列）在界面层的唯一出处。
///
/// 概览页的四类分列与分类明细页的每一行都要说这两句话。它们此前各写一份：明细页走
/// `L10n` 的 `classification.category.*` / `classification.handling.*`，概览页却读
/// 领域层里硬编码的中文（`DataCategory.displayName` / `handling`）——于是同一句话有两个
/// 出处，概览页还绕开了本地化目录（英文界面上照样显示中文）。
///
/// 现在两页都从这里取，文案本体仍然只有一处——资源目录里的
/// `zh-Hans.lproj` / `en.lproj`（`L10n.Key`）。本类型只回答「哪个类别用哪个 key」。
///
/// 领域层不再携带面向用户的文案：`DataCategory.displayOrder` 只保留顺序与
/// `isArchivableNow` 这类真正属于规则的判断（issue #11 的四类是封闭的）。
public enum CategoryCopy {

    /// 一个类别的名称 key（PRD §5.1「类别」一列）。
    public static func nameKey(for category: DataCategory) -> L10n.Key {
        switch category {
        case .archivableSession: return .classificationCategoryArchivableSession
        case .cacheAndLog: return .classificationCategoryCacheAndLog
        case .protected: return .classificationCategoryProtected
        case .uncertain: return .classificationCategoryUncertain
        }
    }

    /// 一个类别的处理方式 key（PRD §5.1「处理」一列）。
    public static func handlingKey(for category: DataCategory) -> L10n.Key {
        switch category {
        case .archivableSession: return .classificationHandlingArchivableSession
        case .cacheAndLog: return .classificationHandlingCacheAndLog
        case .protected: return .classificationHandlingProtected
        case .uncertain: return .classificationHandlingUncertain
        }
    }

    /// 类别名（`可归档会话` / `Archivable sessions`）。
    public static func nameText(for category: DataCategory, language: AppLanguage? = nil) -> String {
        L10n.text(nameKey(for: category), language: language)
    }

    /// 处理方式（`只展示大小，不动` / `Shown only, never touched`）。
    ///
    /// 这三句是**承诺**：缓存与日志「只展示大小，不动」、受保护「永不触碰」、
    /// 不确定「锁定」。界面不得改写、不得省略（诚实展示）。
    public static func handlingText(for category: DataCategory, language: AppLanguage? = nil) -> String {
        L10n.text(handlingKey(for: category), language: language)
    }
}
