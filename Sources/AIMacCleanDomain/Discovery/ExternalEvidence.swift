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

    /// 两份佐证合并成一份（取并集）。
    ///
    /// 调用方已经采集好一份（测试常这么做），同时又给了安装位置让发现器自己采集时，
    /// 两份都算数——合并而不是二选一，免得「注入的值」意外盖掉「真采集到的值」。
    public func merging(_ other: ExternalEvidence) -> ExternalEvidence {
        ExternalEvidence(
            applicationNames: applicationNames.union(other.applicationNames),
            commandNames: commandNames.union(other.commandNames)
        )
    }

    /// 为一条候选的**规则**找外部佐证。
    ///
    /// 匹配忽略大小写与 `.app` 后缀：`claude-code` 的关键词 `claude` 在
    /// `/Applications/Claude.app` 与 PATH 里的 `claude` 上都算数。
    ///
    /// 传入的词来自**规则**（它声明的关键词 + 它的展示名），不是「目录名碰巧命中的
    /// 关键词」——词表是用户可改的配置，按目录名筛过一遍再拿去找 App，
    /// 等于让「用户词表配得全不全」决定这条候选能不能到「高置信度」（User Story 10）。
    /// 本类型只做纯匹配，采集端仍然完全由调用方注入。
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
    public static func applicationNames(
        inDirectories directories: [String],
        fileSystem: any DiscoveryFileSystem = RealDiscoveryFileSystem()
    ) -> Set<String> {
        var names: Set<String> = []
        for directory in directories {
            guard let entries = try? fileSystem.entryNames(inDirectory: directory) else { continue }
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
    public static func commandNames(
        inDirectories directories: [String],
        fileSystem: any DiscoveryFileSystem = RealDiscoveryFileSystem()
    ) -> Set<String> {
        var names: Set<String> = []
        for directory in directories {
            guard let entries = try? fileSystem.entryNames(inDirectory: directory) else { continue }
            for entry in entries {
                let path = directory + "/" + entry
                guard isExecutableFile(atPath: path, fileSystem: fileSystem) else { continue }
                names.insert(entry)
            }
        }
        return names
    }

    /// 在给出的位置采集一次外部佐证。
    ///
    /// `fileSystem` 默认是真实文件系统；测试注入记录器后，这一次采集访问了哪些目录
    /// 也会被一并记下来（issue #18：一次发现的磁盘访问要能被逐条断言）。
    public static func detect(
        applicationDirectories: [String],
        commandSearchPaths: [String],
        fileSystem: any DiscoveryFileSystem = RealDiscoveryFileSystem()
    ) -> ExternalEvidence {
        ExternalEvidence(
            applicationNames: applicationNames(inDirectories: applicationDirectories, fileSystem: fileSystem),
            commandNames: commandNames(inDirectories: commandSearchPaths, fileSystem: fileSystem)
        )
    }

    private static func isExecutableFile(atPath path: String, fileSystem: any DiscoveryFileSystem) -> Bool {
        guard let attributes = fileSystem.attributes(ofItemAt: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber
        else { return false }
        return permissions.int16Value & 0o111 != 0
    }
}

/// **安装检测**：这台机器上装了哪些 AI 工具（issue #18；PRD §4.3「关联检测」、User Story 10）。
///
/// ## 它是发现入口，不是过滤器
///
/// 采集位置全部由调用方注入（本类型不读 `NSHomeDirectory()`、不读环境变量），因此
/// 「装了什么」这件事可以被完全决定——生产代码给真实的 `/Applications`、`~/Applications`
/// 与 `PATH`，测试给临时目录。
///
/// 检测结果只做两件事：
/// - 把命中的候选从「中」抬到「高」，并在同档内排在前面；
/// - 把佐证写进确认信号，让几个月后还看得懂当初为什么这么判（User Story 19）。
///
/// **它绝不做第三件事：不因为某个 App 不在 `/Applications`、命令不在 `PATH` 上，
/// 就跳过那个工具的工具根检查。** 卸载了工具、磁盘上会话还在，正是这个产品最该帮用户
/// 发现的场景（GLOSSARY 的「移出」流程也依赖它）。因此它只是打分与排序的输入，
/// 不是准入门。
public struct InstallationDetection: Equatable, Sendable {

    /// 采集同名 App 的目录（`/Applications`、`~/Applications`）。
    public var applicationDirectories: [String]

    /// 采集 PATH 命令的目录。
    public var commandSearchPaths: [String]

    public init(applicationDirectories: [String] = [], commandSearchPaths: [String] = []) {
        self.applicationDirectories = applicationDirectories
        self.commandSearchPaths = commandSearchPaths
    }

    /// 不做安装检测：每个候选都只能靠结构指纹拿到「中」。
    public static let none = InstallationDetection()

    /// 采集一次安装证据。
    public func detect(fileSystem: any DiscoveryFileSystem = RealDiscoveryFileSystem()) -> ExternalEvidence {
        ExternalEvidenceCollector.detect(
            applicationDirectories: applicationDirectories,
            commandSearchPaths: commandSearchPaths,
            fileSystem: fileSystem
        )
    }
}
