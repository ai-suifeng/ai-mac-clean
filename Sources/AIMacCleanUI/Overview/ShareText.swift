import Foundation

/// 占比（百分比）的展示入口（issue #28；PRD §9「可归档占比」）。
///
/// 与 `ByteSizeFormatter` 同一套纪律：**同一个数字在任何系统语言下写法一致**，
/// 因此这里不用 `NumberFormatter` 的区域格式，而是固定的 `%.2f` + 手工去尾零。
///
/// 为什么至多两位小数：PRD §14.1 点名的 Claude Code 是 **0.15%**。
/// 一位小数会显示成「0.2%」（夸大），整数会显示成「0%」（假装没有），
/// 对一个以「如实展示」为卖点的页面都不合格。
public enum ShareText {

    /// 把 0…1 的占比格式化成百分比文案：`0.0015` → `0.15%`，`0.5` → `50%`。
    ///
    /// 负数（不该出现，但算得出来）按 0 显示，不给用户看一个负占比。
    public static func string(fromShare share: Double) -> String {
        let percent = max(0, share) * 100
        var text = String(format: "%.2f", percent)
        while text.contains("."), text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text + "%"
    }
}
