import Foundation

/// 安装位置声明的种类（issue #19；PRD §4.3「关联检测」）。
///
/// 只有两种：安装佐证只分「同名 App 在」与「同名命令在」两类，
/// 而这两类来自两种形态的路径声明。
public enum InstallationKind: String, Codable, CaseIterable, Equatable, Sendable {
    /// App 包（`/Applications/Cursor.app`、`~/Applications/Cursor.app`）。
    case appBundle
    /// 可执行文件（`~/.claude/local/claude`、`/opt/homebrew/bin/codex`）。
    case executable
}

/// 一个安装位置声明：规则文件里写的「这个工具装在这儿」。
///
/// ## 为什么要声明，而不是去通用位置里找
///
/// 早先的安装检测把 `/Applications`、`~/Applications` 与整条 PATH 交给采集端逐个列举，
/// 于是浅扫为了确认 5 个已知工具装了没有，翻了本机几百个 App 与几百个可执行文件——
/// 那不是 AI 工具自己的目录，也正好是浅扫刚刚砍掉的「通用位置扫描」。
///
/// 现在反过来：**规则声明哪条，就只 stat 哪条**（不列举）。声明路径不存在只是
/// 「没有安装佐证」，工具的数据目录照常进候选、停在「中」——安装佐证只影响
/// 「高 / 中」与同档排序，不是过滤器（PRD §4.3、issue #18 的既定口径）。
///
/// `path` 与 `roots[].path` 同一套写法：`~/…`（相对 `$HOME`）或绝对路径。
public struct DeclaredInstallation: Codable, Equatable, Sendable {

    /// 安装路径。`~/…` 相对 `$HOME`；否则必须是绝对路径。
    public let path: String

    /// 这条路径的形态：App 包还是可执行文件。
    public let kind: InstallationKind

    public init(path: String, kind: InstallationKind) {
        self.path = path
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case path, kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)

        // 种类是封闭枚举：读不懂的种类要指名道姓，而不是一个裸的类型错误。
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let kind = InstallationKind(rawValue: rawKind) else {
            throw RuleFormatError.unknownInstallationKind(rawKind)
        }
        self.kind = kind

        guard hasWellFormedPath else {
            throw RuleFormatError.invalidFieldValue(
                field: "installations.path",
                reason: "路径必须以 ~/ 开头（相对 $HOME）或以 / 开头（绝对路径）：\(path)"
            )
        }
        if kind == .appBundle, !path.lowercased().hasSuffix(".app") {
            throw RuleFormatError.invalidFieldValue(
                field: "installations.path",
                reason: "kind 为 appBundle 时路径必须指向 .app 包：\(path)"
            )
        }
    }

    /// 路径形状是否合法：`~/` 后面要有内容，绝对路径同理（与 `ToolRoot` 同一套口径）。
    var hasWellFormedPath: Bool {
        guard path.hasPrefix("~/") || path.hasPrefix("/") else { return false }
        return path.count > (path.hasPrefix("~/") ? 2 : 1)
    }
}
