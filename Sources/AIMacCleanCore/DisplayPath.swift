import Foundation

/// 路径展示工具。
///
/// 只负责「怎么把路径显示给用户看」，不做任何安全判定——受保护判定与移除前校验在 Rules / 归档层。
public enum DisplayPath {

    /// 展示一个路径：位于 `homeDirectory` 之下时缩写成 `~/` 形式。
    ///
    /// 主目录由调用方传入，而不是在这里读 `NSHomeDirectory()`：
    /// 测试才能在临时目录上跑，本层也不会在任何路径上隐式依赖真实用户主目录。
    public static func abbreviate(_ path: String, homeDirectory: String) -> String {
        let normalizedPath = standardize(path)
        let normalizedHome = standardize(homeDirectory)

        guard !normalizedHome.isEmpty, normalizedPath.hasPrefix(normalizedHome) else {
            return normalizedPath
        }
        // 前缀相同但不是子路径，例如 `/Users/example-backup` 对 `/Users/example`。
        guard normalizedPath == normalizedHome
            || normalizedPath.hasPrefix(normalizedHome + "/")
        else {
            return normalizedPath
        }

        let remainder = String(normalizedPath.dropFirst(normalizedHome.count))
        // 主目录本身显示成 `~`，其余显示成 `~/.codex`。
        return remainder.isEmpty ? "~" : "~" + remainder
    }

    /// 去掉重复与尾随分隔符，不解析符号链接、不展开 `~`。
    private static func standardize(_ path: String) -> String {
        var text = path
        while text.count > 1, text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }
}
