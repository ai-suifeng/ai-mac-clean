import Foundation

/// 路径模式对**具体相对路径**的匹配（issue #12：发现器的结构指纹比对）。
///
/// 语义（issue #10 解析、issue #11 保护单调性判定、issue #12 匹配）：
///
/// - 分段用 `/` 比较，段数必须一致（`**` 除外，它吃掉剩下的**全部**分段且至少一段）；
/// - `*` 匹配单段内任意文本；`<uuid>` 只可能是十六进制与短横线；
///   `<encodedPath>` / `<名字>` 是**不含点**的单段标识符；`[.zst]` 是可选后缀；
/// - 忽略大小写（macOS 默认文件系统大小写不敏感，忽略大小写只会多命中、不会漏命中）。
///
/// 本文件只把既有的匹配能力公开出来，语义仍由 `PatternMatching` 单点实现。
public extension PathPattern {

    /// 这条模式是否覆盖某个相对路径（相对工具根目录、以 `/` 分隔）。
    func matches(relativePath: String) -> Bool {
        PatternMatching.matches(self, relativePath: relativePath)
    }

    /// 是否覆盖给定相对路径中的任意一条。
    func matchesAny(relativePaths: some Sequence<String>) -> Bool {
        relativePaths.contains { matches(relativePath: $0) }
    }
}
