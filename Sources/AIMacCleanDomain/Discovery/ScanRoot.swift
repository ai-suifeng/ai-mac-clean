import Foundation

/// 一个浅扫扫描根：发现器只检查它的一级子目录（PRD §4.1 第 1 步、§4.2）。
///
/// 扫描根**由调用方注入**（本类型不读 `NSHomeDirectory()`）：测试才能在临时目录树上跑，
/// 真实数据目录绝不参与（PRD §13 第 3 条）。`standard(forHomeDirectory:)` 只是
/// PRD §4.2 那份清单的实现，不是默认值。
public struct ScanRoot: Equatable, Sendable {

    /// 这个扫描根下哪些一级子目录值得看。
    public enum EntryFilter: Equatable, Sendable {
        /// 只看隐藏目录（`~` 下的 `.claude`、`.codex` …）。
        case hiddenDirectoriesOnly
        /// 所有一级子目录（`~/.local/share/opencode`、`~/Library/Application Support/Cursor` …）。
        case allEntries
    }

    /// 扫描根的绝对路径。
    public let path: String

    /// 一级子目录的筛选口径。
    public let entryFilter: EntryFilter

    public init(path: String, entryFilter: EntryFilter = .allEntries) {
        self.path = path
        self.entryFilter = entryFilter
    }

    /// PRD §4.2 的标准扫描根清单。
    ///
    /// 路径不存在不是错误（User Story 22「规则容忍缺失」）：浅扫遇到不存在的目录
    /// 只是**没有可看的东西**，不会让整轮扫描失败。
    public static func standard(forHomeDirectory home: String) -> [ScanRoot] {
        let prefix = home.hasSuffix("/") ? String(home.dropLast()) : home
        return [
            // `~` 下的隐藏目录。
            ScanRoot(path: prefix, entryFilter: .hiddenDirectoriesOnly),
            // `~/.config`、`~/.local/share`、`~/.cache` 的一级子目录。
            ScanRoot(path: prefix + "/.config"),
            ScanRoot(path: prefix + "/.local/share"),
            ScanRoot(path: prefix + "/.cache"),
            // `~/Library` 下四个位置的一级子目录。
            ScanRoot(path: prefix + "/Library/Application Support"),
            ScanRoot(path: prefix + "/Library/Caches"),
            ScanRoot(path: prefix + "/Library/Logs"),
            ScanRoot(path: prefix + "/Library/Containers"),
            ScanRoot(path: prefix + "/Library/Group Containers"),
        ]
    }
}
