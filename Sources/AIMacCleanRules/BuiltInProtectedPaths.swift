import Foundation

/// 一条内置受保护路径条目。
///
/// 全部为只读值类型，清单本体以 `static let` 编译进二进制，
/// 没有任何运行时修改入口（issue #9 硬性约束）。
public struct BuiltInProtectedRule: Hashable, Sendable {

    /// 条目标识，出错与测试里可读，例如 `claude-code/settings`。
    public let identifier: String

    /// 条目作用域：按已知工具根判定、按主目录判定，还是未知位置的凭证文件名兜底。
    public let scope: BuiltInProtectedScope

    /// 通配符模式。`*` 匹配任意字符，忽略大小写。
    ///
    /// - `kind == .file`：与相对路径的**最后一段**比较（`settings*.json`、`*.sqlite`）。
    /// - `kind == .directory`：与相对路径的**第一段**比较，命中即覆盖整棵子树（`skills*`）。
    public let pattern: String

    /// 条目描述的是文件还是目录。
    public let kind: ProtectedPathKind

    public init(identifier: String, scope: BuiltInProtectedScope, pattern: String, kind: ProtectedPathKind) {
        self.identifier = identifier
        self.scope = scope
        self.pattern = pattern
        self.kind = kind
    }
}

/// 内置受保护条目的作用域。
public enum BuiltInProtectedScope: Hashable, Sendable {

    /// 已知工具根（GLOSSARY「工具根目录」），identifier 取自 PRD §5.4 的工具名。
    case toolRoot(String)

    /// 用户主目录下的跨工具条目（`~/.claude.json` 等位于工具根之外）。
    case homeDirectory

    /// 纯凭证文件名（`auth*`、`oauth_creds.json`、`*credentials*`）。
    ///
    /// 凭证文件名不区分工具，因此**任何位置**都保护：即使它出现在某个工具根下，
    /// 也绝不因为「那张清单是给别的工具写的」而失去保护。
    case credentialFileName

    /// 未被识别的位置（工具根目录名不在内置清单内）上的保守文件名兜底（PRD §5.5）。
    case unknownLocation
}

/// 条目描述的是文件还是目录。
public enum ProtectedPathKind: String, Hashable, Sendable {
    case file
    case directory
}

/// 一次受保护命中。
public struct ProtectedMatch: Hashable, Sendable {

    /// 命中的内置条目标识。
    public let ruleIdentifier: String

    /// 命中的作用域。
    public let scope: BuiltInProtectedScope

    /// 命中时用的相对路径（作用域为主目录时同样相对主目录）。
    public let matchedRelativePath: String

    /// 命中方式：说明是按链接位置、真实目标还是文件名兜底判定的。
    public let matchedVia: ProtectedMatchSource

    public init(
        ruleIdentifier: String,
        scope: BuiltInProtectedScope,
        matchedRelativePath: String,
        matchedVia: ProtectedMatchSource
    ) {
        self.ruleIdentifier = ruleIdentifier
        self.scope = scope
        self.matchedRelativePath = matchedRelativePath
        self.matchedVia = matchedVia
    }
}

/// 判定命中的来源。
public enum ProtectedMatchSource: String, Hashable, Sendable {

    /// 按「工具根 + 相对路径」判定，未解析符号链接。
    case toolRootRelativePath

    /// 按「工具根 + 相对路径」判定，路径已解析符号链接。
    case resolvedRelativePath

    /// 按「主目录 + 相对路径」判定。
    case homeRelativePath

    /// 按文件名黑名单判定（纯凭证文件名，或 PRD §5.5 的未识别位置黑名单）。
    case fileNameBlacklist

    /// 落在某个内置受保护目录的真实目标之下（`~/.codex/skills` → `~/.agents/skills`）。
    case symlinkRealTarget
}

/// 内置受保护清单（issue #9；PRD §5.4 / §8.1 / §14.5；GLOSSARY「受保护」）。
///
/// 这是保护单调性的**下界**：它在编译期固定，任何规则文件或用户操作都无法削弱它。
/// 本票只负责「判定」，规则集准入的单调性校验属于 issue #11。
///
/// ## 匹配语义
///
/// 判定一律按「工具根目录 + 相对路径」进行，不做全盘字符串匹配：
/// Codex 的 `config.toml` 不因为同名而让 Claude 根下的 `config.toml` 受保护。
///
/// ## 符号链接
///
/// 判定同时看链接位置与真实目标：`~/.codex/skills` 形态的链接按链接本身命中内置条目，
/// 而 `~/.agents/skills` 这个真实目标本身也受保护（PRD §8.2 / §14.5、验收 A3 / A8）。
public enum BuiltInProtectedPaths {

    /// 编译进二进制的内置受保护清单。
    ///
    /// `let` + 不可变值类型：没有 setter、没有增删接口，运行时无法改写。
    ///
    /// 内容以 PRD §5.4 的实测结论为准；标注「补充」的条目是文档未逐条列出、
    /// 但按「配置 / 凭证 / 技能 / 命令 / MCP 设置一律受保护」补齐的保守条目。
    public static let rules: [BuiltInProtectedRule] = [
        // MARK: Claude Code（`~/.claude`）

        .init(identifier: "claude-code/settings", scope: .toolRoot(claudeCode), pattern: "settings*.json", kind: .file),
        .init(identifier: "claude-code/mcp", scope: .toolRoot(claudeCode), pattern: "mcp*.json", kind: .file),
        .init(identifier: "claude-code/credentials", scope: .toolRoot(claudeCode), pattern: ".credentials*", kind: .file),
        .init(identifier: "claude-code/history", scope: .toolRoot(claudeCode), pattern: "history.jsonl", kind: .file),
        .init(identifier: "claude-code/skills", scope: .toolRoot(claudeCode), pattern: "skills*", kind: .directory),
        .init(identifier: "claude-code/commands", scope: .toolRoot(claudeCode), pattern: "commands*", kind: .directory),
        .init(identifier: "claude-code/agents", scope: .toolRoot(claudeCode), pattern: "agents*", kind: .directory),
        .init(identifier: "claude-code/plugins", scope: .toolRoot(claudeCode), pattern: "plugins*", kind: .directory),
        .init(identifier: "claude-code/shell-snapshots", scope: .toolRoot(claudeCode), pattern: "shell-snapshots*", kind: .directory),
        // 补充：旧版本残留的遥测配置目录，与 `statsig/` 同样属于配置而非会话数据。
        .init(identifier: "claude-code/statsig", scope: .toolRoot(claudeCode), pattern: "statsig*", kind: .directory),

        // MARK: Codex CLI（`~/.codex`）

        .init(identifier: "codex-cli/config", scope: .toolRoot(codexCLI), pattern: "config.toml*", kind: .file),
        .init(identifier: "codex-cli/auth", scope: .toolRoot(codexCLI), pattern: "auth*", kind: .file),
        .init(identifier: "codex-cli/prompts", scope: .toolRoot(codexCLI), pattern: "prompts*", kind: .directory),
        // 补充：`~/.codex/skills` → `~/.agents/skills`（PRD §14.5），技能必须受保护。
        .init(identifier: "codex-cli/skills", scope: .toolRoot(codexCLI), pattern: "skills*", kind: .directory),
        .init(identifier: "codex-cli/sqlite", scope: .toolRoot(codexCLI), pattern: "*.sqlite*", kind: .file),

        // MARK: Cursor（`~/.cursor`）

        .init(identifier: "cursor/extensions", scope: .toolRoot(cursor), pattern: "extensions*", kind: .directory),
        .init(identifier: "cursor/plugins", scope: .toolRoot(cursor), pattern: "plugins*", kind: .directory),
        .init(identifier: "cursor/worktrees", scope: .toolRoot(cursor), pattern: "worktrees*", kind: .directory),
        .init(identifier: "cursor/skills", scope: .toolRoot(cursor), pattern: "skills*", kind: .directory),
        .init(identifier: "cursor/mcp", scope: .toolRoot(cursor), pattern: "mcp*.json", kind: .file),
        .init(identifier: "cursor/hooks", scope: .toolRoot(cursor), pattern: "hooks*.json", kind: .file),
        // 补充：Cursor 的命令与子代理配置同样不是会话数据。
        .init(identifier: "cursor/commands", scope: .toolRoot(cursor), pattern: "commands*", kind: .directory),
        .init(identifier: "cursor/agents", scope: .toolRoot(cursor), pattern: "agents*", kind: .directory),

        // MARK: DeepSeek Harness（`…/deepseek-harness-desktop/harness-home`）

        .init(identifier: "deepseek-harness/settings", scope: .toolRoot(deepSeekHarness), pattern: "settings*", kind: .file),
        .init(identifier: "deepseek-harness/credentials", scope: .toolRoot(deepSeekHarness), pattern: ".credentials*", kind: .file),
        .init(identifier: "deepseek-harness/storages", scope: .toolRoot(deepSeekHarness), pattern: "storages*", kind: .directory),
        .init(identifier: "deepseek-harness/profiles", scope: .toolRoot(deepSeekHarness), pattern: "profiles*", kind: .directory),
        // 补充：技能与命令同样不是会话数据。
        .init(identifier: "deepseek-harness/skills", scope: .toolRoot(deepSeekHarness), pattern: "skills*", kind: .directory),
        .init(identifier: "deepseek-harness/commands", scope: .toolRoot(deepSeekHarness), pattern: "commands*", kind: .directory),
        .init(identifier: "deepseek-harness/mcp", scope: .toolRoot(deepSeekHarness), pattern: "mcp*.json", kind: .file),

        // MARK: 主目录下的跨工具条目（位于工具根之外，PRD §5.4）

        .init(identifier: "home/claude-state", scope: .homeDirectory, pattern: ".claude.json*", kind: .file),
        .init(identifier: "home/codex-state", scope: .homeDirectory, pattern: ".codex-global-state.json*", kind: .file),
        // `~/.codex/skills` 与 `~/.opencode/skills` 的真实目标（PRD §14.5）。
        .init(identifier: "home/shared-skills", scope: .homeDirectory, pattern: ".agents/skills*", kind: .directory),

        // MARK: 纯凭证文件名：与工具无关，任何位置都保护（issue #9 硬性约束的保守取值）

        .init(identifier: "credential/auth", scope: .credentialFileName, pattern: "auth*", kind: .file),
        .init(identifier: "credential/oauth", scope: .credentialFileName, pattern: "oauth_creds.json", kind: .file),
        .init(identifier: "credential/credentials", scope: .credentialFileName, pattern: "*credentials*", kind: .file),

        // MARK: 未识别位置的文件名黑名单（PRD §5.5）

        .init(identifier: "unknown/config", scope: .unknownLocation, pattern: "config*", kind: .file),
        .init(identifier: "unknown/settings", scope: .unknownLocation, pattern: "settings*", kind: .file),
        .init(identifier: "unknown/history", scope: .unknownLocation, pattern: "history.jsonl", kind: .file),
        .init(identifier: "unknown/log", scope: .unknownLocation, pattern: "*.log", kind: .file),
        .init(identifier: "unknown/token", scope: .unknownLocation, pattern: "*token*", kind: .file),
        .init(identifier: "unknown/secret", scope: .unknownLocation, pattern: "*secret*", kind: .file),
    ]

    // MARK: - 工具标识

    public static let claudeCode = "claude-code"
    public static let codexCLI = "codex-cli"
    public static let cursor = "cursor"
    public static let deepSeekHarness = "deepseek-harness"

    /// 工具根目录相对主目录的位置（PRD §5.4 实测）。
    static let rootRelativePaths: [String: String] = [
        claudeCode: ".claude",
        codexCLI: ".codex",
        cursor: ".cursor",
        deepSeekHarness: "Library/Application Support/deepseek-harness-desktop/harness-home",
    ]

    // MARK: - 查询

    /// 给定工具根判定其作用域。
    ///
    /// 已知工具根按**最后一段目录名**识别（`.claude` / `.codex` / `.cursor` / `harness-home`），
    /// 于是同一套内置条目既能作用于真实主目录，也能作用于形状相同的临时目录树。
    public static func scope(ofToolRoot root: String) -> BuiltInProtectedScope {
        let normalized = ProtectedPathMath.normalize(root)
        let name = ProtectedPathMath.components(of: normalized).last ?? normalized

        for (identifier, relativeRoot) in rootRelativePaths
        where ProtectedPathMath.components(of: relativeRoot).last == name {
            return .toolRoot(identifier)
        }
        return .unknownLocation
    }

    /// 某路径是否受内置保护。
    public static func isProtected(
        _ path: String,
        underToolRoot toolRoot: String,
        homeDirectory: String,
        listing: any ProtectedPathDirectoryListing = RealProtectedPathDirectoryListing()
    ) -> Bool {
        protection(
            forPath: path,
            underToolRoot: toolRoot,
            homeDirectory: homeDirectory,
            listing: listing
        ) != nil
    }

    /// 某路径命中的内置受保护条目；未命中返回 `nil`。
    ///
    /// `homeDirectory` 由调用方显式传入，本类型不读 `NSHomeDirectory()`：
    /// 测试才能在临时目录上跑，本层也不会在隐式依赖真实用户主目录的情况下做安全判定。
    ///
    /// `listing` 是通配展开读磁盘的那一层（issue #19）。默认真实文件系统；
    /// 注入记录器后可以断言「这次判定列举了哪些目录」，而**主目录一次都不该出现**。
    ///
    /// 判定**不做任何缓存**：宁可每次重算，也不因缓存过期漏掉一个刚出现的符号链接——
    /// 漏判的后果是动了凭证，而多算一次的开销只是多几次目录列举。
    ///
    /// 语义的**唯一实现**在 `ProtectedPathContext`（issue #29）：本方法就是
    /// 「建一个只活这一次调用的快照 + 按原语义解析这条路径」。深扫这类逐文件判定的调用方
    /// 改用一次扫描一份的快照（`ProtectedPathContext`），本入口保持不变，逐次调用者行为不变。
    public static func protection(
        forPath path: String,
        underToolRoot toolRoot: String,
        homeDirectory: String,
        listing: any ProtectedPathDirectoryListing = RealProtectedPathDirectoryListing()
    ) -> ProtectedMatch? {
        ProtectedPathContext(
            toolRoot: toolRoot,
            homeDirectory: homeDirectory,
            listing: listing
        ).protection(forPath: path)
    }

    /// 命中条目所属的已知工具标识；主目录条目与文件名兜底不属于任何已知工具。
    public static func protectingTool(
        forPath path: String,
        underToolRoot toolRoot: String,
        homeDirectory: String
    ) -> String? {
        guard case let .toolRoot(identifier) = protection(
            forPath: path,
            underToolRoot: toolRoot,
            homeDirectory: homeDirectory
        )?.scope else { return nil }
        return identifier
    }
}
