import Foundation

/// 结构指纹之外的**外部佐证**（PRD §4.3「关联检测」、User Story 10）。
///
/// ## 生产环境不再自己采集（issue #19）
///
/// 安装佐证的唯一来源是**规则文件声明的安装路径**：`ToolDiscoverer` 对
/// `ToolRule.installations` 里的每一条逐条 `stat`，命中就产生合成 `.application` / `.command`
/// 佐证。它不再列举 `/Applications`、`~/Applications` 或 PATH 的任何目录。
///
/// 本类型保留为一个**纯值类型 + 纯匹配**：不做任何 I/O，调用方可以注入一份已确定的佐证
/// （测试常这么做），`corroborations(forKeywords:)` 把它按规则的关键词匹配出来。
/// 这一段没有文件系统访问，因此不可能把「扫描范围」扩大到规则之外。
public struct ExternalEvidence: Equatable, Sendable {

    /// 已安装的应用名（去掉 `.app` 后缀，如 `Claude`）。
    public let applicationNames: Set<String>

    /// 已安装的命令名（如 `claude`）。
    public let commandNames: Set<String>

    public init(applicationNames: Set<String> = [], commandNames: Set<String> = []) {
        self.applicationNames = applicationNames
        self.commandNames = commandNames
    }

    /// 没有任何外部佐证。
    public static let none = ExternalEvidence()

    /// 为一条候选的**规则**找外部佐证。
    ///
    /// 匹配忽略大小写与 `.app` 后缀：`claude-code` 的关键词 `claude` 在
    /// `Claude.app` 与命令 `claude` 上都算数。
    ///
    /// 传入的词来自**规则**（它声明的关键词 + 它的展示名），不是「目录名碰巧命中的
    /// 关键词」——词表是用户可改的配置，按目录名筛过一遍再拿去找 App，
    /// 等于让「用户词表配得全不全」决定这条候选能不能到「高置信度」（User Story 10）。
    public func corroborations(forKeywords keywords: [String]) -> [ExternalCorroboration] {
        var result: [ExternalCorroboration] = []
        for keyword in keywords {
            let normalized = keyword.lowercased()
            for name in applicationNames.sorted() where name.lowercased() == normalized {
                result.append(.application(name))
            }
            for name in commandNames.sorted() where name.lowercased() == normalized {
                result.append(.command(name))
            }
        }
        return result
    }
}
