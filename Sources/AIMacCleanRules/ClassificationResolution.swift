import Foundation

/// 同一路径同时命中多条分类条目时，按**判定顺序**归属到唯一一类（issue #25 验收 6）。
///
/// 判定顺序从最高档到最低档：
///
/// 1. `protected`（受保护）—— 永不触碰；内置受保护清单是下界，任何规则都不能把它改判。
/// 2. `uncertain`（不确定）—— 无法安全分类的数据，仅展示占用（PRD §5.1）。
/// 3. `cacheAndLog`（缓存与日志）—— 仅展示占用，不动（PRD §2.3）。
/// 4. `archivableSession`（可归档会话）—— 最低档：没有任何更高档承诺时才成立。
///
/// 取向只有一个：**越不容易丢数据越靠前**。
///
/// - 受保护排第一，因为它同时是代码层强制的不变量（PRD §8.1）：一条宽泛的可归档声明
///   不能盖过同一路径上的受保护声明。
/// - 「不确定」排在「缓存与日志」前面，是因为两句承诺的保守程度不同：
///   「认不出来，仅展示占用」比「这是缓存」更保守——后者可能被读成「可以清」（PRD §2.3）。
///
/// 判定顺序与规则文件里**声明的先后无关**：规则文件可以随便调整条目顺序，
/// 结果都不变，深扫因此不需要理解 JSON 的书写顺序。
public enum ClassificationResolution {

    /// 分类判定顺序，从最高档到最低档。
    public static let precedence: [DataCategory] = [
        .protected,
        .uncertain,
        .cacheAndLog,
        .archivableSession,
    ]

    /// 一组命中类别里判定顺序最高的那一类；空集合返回 `nil`。
    public static func preferred(_ categories: [DataCategory]) -> DataCategory? {
        for category in precedence where categories.contains(category) {
            return category
        }
        return nil
    }

    /// 未命中任何分类条目时的归属：**不确定**（仅展示占用，不归档）。
    ///
    /// 规则没有声明过的数据就是「无法安全分类」的数据（PRD §5.1），因此默认落在
    /// 不确定档。默认值只有一个方向：**绝不默认成可归档**——那等于让引擎去归档一份
    /// 规则根本没读懂的数据，而四类占用总得有个归属，不能留下第五类「未分类」。
    public static let unclassified: DataCategory = .uncertain

    /// 按判定顺序解析一组命中类别；未命中任何条目时取 `unclassified`。
    public static func resolve(matches categories: [DataCategory]) -> DataCategory {
        preferred(categories) ?? unclassified
    }
}
