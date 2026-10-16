import Foundation

/// 「可归档占比」的**唯一定义**：门槛、判定与百分比文案（PRD §9）。
///
/// ## 为什么要有它
///
/// 概览页与分类明细页此前各写一份：
///
/// - 门槛两个名字（`ToolScanReport.negligibleArchivableShareThreshold` 与
///   `ClassificationDetailPresenter.tinyArchivableShareThreshold`，都是 1%）；
/// - 判定两个零值守卫：概览页要求「确实有可归档字节」才算极小，明细页只看
///   「占比 < 1%」——可归档为 0 的工具因此被明细页标成「极小」，而概览页不标，
///   同一台工具两页说法矛盾；
/// - 百分比两套格式化（概览页 `%.2f` 会在极小时显示 `0%`，明细页会显示 `<0.01%`）。
///
/// 现在只有这一处实现，两页都消费它。可见的**措辞**仍由各页的 L10n 决定
/// （概览一句「可归档占比极小」、明细一句更长的说明）——但那只是「怎么说」，
/// 不再是「算不算」。
public enum ArchivableShare {

    /// 「可归档占比极小」的判定门槛：**1%**，严格小于（正好 1% 不算极小）。
    ///
    /// 文档没有给阈值（PRD §9 只说「收益极低的工具如实标注」，§14.1 只举了
    /// Claude Code 0.15%），这里取保守的一侧。依据是实测分布的两端：被点名的
    /// Claude Code 是 0.15%，而真正可观的 Codex 是 61%、Cursor 4.7%、OpenCode 2.8%，
    /// 1% 把两者干净地分开，且偏向「宁可多标一句，也不让用户误以为有收益」。
    public static let negligibleThreshold = 0.01

    /// 占比：可归档字节 ÷ 总字节；总字节为 0 时返回 0（不返回 NaN）。
    public static func share(of bytes: Int64, totalBytes: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytes) / Double(totalBytes)
    }

    /// 收益是不是低到必须如实标注（PRD §9）。
    ///
    /// 两个条件缺一不可：**确实有可归档字节**（否则 0 不叫「极小」，叫「没有」，
    /// 该由数字本身说明），且占比低于门槛。
    ///
    /// 判定基于**原始比值**，不看格式化后的百分比：`0.9999%` 仍然是极小，
    /// 不会因为界面上四舍五入成 `1%` 就被放过。
    public static func isNegligible(archivableBytes: Int64, totalBytes: Int64) -> Bool {
        archivableBytes > 0 && share(of: archivableBytes, totalBytes: totalBytes) < negligibleThreshold
    }

    /// 占比的展示文案：最多两位小数，去掉多余的零（`97.5%`、`0.14%`、`2%`、`0%`）。
    ///
    /// 手工格式化而不用 `NumberFormatter`：后者的输出跟系统语言走（千分位、小数点符号），
    /// 而同一个数字在任何系统下都必须长得一样（与 `ByteSizeFormatter` 同一条纪律）。
    ///
    /// 负数（不该出现，但算得出来）按 0 显示。非零但小于 0.01% 的占比显示成 `<0.01%`
    /// 而不是 `0%`——「有，但极小」与「一点都没有」是两件事（PRD §9 的诚实展示）。
    public static func percentText(_ share: Double) -> String {
        guard share > 0 else { return "0%" }
        let basisPoints = Int((share * 10_000).rounded())
        guard basisPoints > 0 else { return "<0.01%" }

        let whole = basisPoints / 100
        let fraction = basisPoints % 100
        if fraction == 0 { return "\(whole)%" }
        if fraction % 10 == 0 { return "\(whole).\(fraction / 10)%" }
        return "\(whole).\(String(format: "%02d", fraction))%"
    }
}
