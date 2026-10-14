import Foundation

/// 结构指纹之外的**外部佐证**：同名 App、PATH 中的同名命令（PRD §4.3「关联检测」、User Story 10）。
///
/// 采集点全部由调用方注入：测试可以给出一个确定的集合，生产代码自己决定去哪儿找
/// （`detect(applicationDirectories:commandSearchPaths:)`）。本类型不做任何 I/O——
/// 列举 `/Applications` 与 PATH 是文件系统的事，属于采集端的职责。
public struct ExternalEvidence: Equatable, Sendable {

    /// 已安装的应用名（去掉 `.app` 后缀，如 `Claude`）。
    public let applicationNames: Set<String>

    /// PATH 中的命令名（如 `claude`）。
    public let commandNames: Set<String>

    public init(applicationNames: Set<String> = [], commandNames: Set<String> = []) {
        self.applicationNames = applicationNames
        self.commandNames = commandNames
    }

    /// 没有任何外部佐证。
    public static let none = ExternalEvidence()

    /// 规则命中后，为它找外部佐证。
    ///
    /// 匹配忽略大小写与 `.app` 后缀：`claude-code` 的关键词 `claude` 在
    /// `/Applications/Claude.app` 与 PATH 里的 `claude` 上都算数。
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

/// 外部佐证的采集端：列举应用目录与命令搜索路径。
///
/// 单独成入口而不是塞进 `ExternalEvidence` 本身，是为了让「佐证是什么」保持成一个
/// 纯值类型：判定逻辑可以被断言，而列举行为留在采集端。
public enum ExternalEvidenceCollector {

    /// 列举应用目录下的应用名（`Claude.app` → `Claude`）。
    ///
    /// 只读目录的一级，不跟随符号链接；目录读不到只是**没有佐证**，不算错误。
    public static func applicationNames(inDirectories directories: [String]) -> Set<String> {
        var names: Set<String> = []
        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.lowercased().hasSuffix(".app") {
                names.insert(String(entry.dropLast(4)))
            }
        }
        return names
    }

    /// 列举若干命令搜索目录下的可执行文件名。
    ///
    /// PATH 里的命令常常是指向别处的符号链接（`/opt/homebrew/bin` → `Cellar`），
    /// 这里读的是**链接自身的文件名**（`claude`），不解析链接目标——
    /// 与「不跟随符号链接」的其余部分保持一致。
    public static func commandNames(inDirectories directories: [String]) -> Set<String> {
        var names: Set<String> = []
        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries {
                let path = directory + "/" + entry
                guard isExecutableFile(atPath: path) else { continue }
                names.insert(entry)
            }
        }
        return names
    }

    /// 在给出的位置采集一次外部佐证。
    public static func detect(applicationDirectories: [String], commandSearchPaths: [String]) -> ExternalEvidence {
        ExternalEvidence(
            applicationNames: applicationNames(inDirectories: applicationDirectories),
            commandNames: commandNames(inDirectories: commandSearchPaths)
        )
    }

    private static func isExecutableFile(atPath path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber
        else { return false }
        return permissions.int16Value & 0o111 != 0
    }
}
