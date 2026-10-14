import Foundation

import AIMacCleanRules

/// 浅扫发现器（Seam 1；issue #12 / spec #7 §发现管线）。
///
/// 输入：若干**扫描根**（注入，测试用临时目录树）与一份**已验证可用的规则集**
/// （`RuleSetAdmission` 的 `usableRules`）。输出：候选列表。
///
/// ## 不变式
///
/// 1. **结构指纹才准入**：目录必须落在某条规则声明的工具根上、并且命中该规则声明的
///    结构特征（会话文件路径模式 / 会话目录形态 / 项目目录形态），才成为候选。
///    名称关键词只参与排序，永远不参与准入（User Story 8、9、PRD A1）。
/// 2. **不跟随符号链接**：遍历与指纹匹配都不解析符号链接（User Story 12）。
///    候选的受保护判定另按链接真实目标进行（issue #9）。
/// 3. **浅扫**：只看扫描根的一级子目录，不递归计算体积（User Story 2、44）。
/// 4. **错误按目录隔离**：读不到一个目录只跳过它自己，并在结果里说明；
///    整体扫描不失败，空结果是成功（User Story 13、14）。
/// 5. **只读元数据与文件头**：文件内容最多读 `headerByteLimit` 字节，且只读开头
///    （User Story 11、PRD §13 第 3 条）。
public struct ToolDiscoverer {

    private let rules: [ToolRule]
    private let hints: DiscoveryHints
    private let externalEvidence: ExternalEvidence
    private let homeDirectory: String

    /// - Parameters:
    ///   - rules: **已准入**的规则集（`RuleSetAdmission.admit(...).usableRules`）。
    ///   - hints: 名称关键词与负向名单。默认空：没有词表就只是不排序、不降权。
    ///   - externalEvidence: 外部佐证（同名 App / PATH 命令）。默认空。
    ///   - homeDirectory: 把规则里的 `~/` 展开成绝对路径用的主目录，由调用方给出。
    public init(
        rules: [ToolRule],
        hints: DiscoveryHints = .none,
        externalEvidence: ExternalEvidence = .none,
        homeDirectory: String
    ) {
        self.rules = rules
        self.hints = hints
        self.externalEvidence = externalEvidence
        self.homeDirectory = homeDirectory
    }

    /// 按 PRD §4.2 的标准扫描根浅扫一次。
    public func discover() -> DiscoveryResult {
        discover(scanRoots: ScanRoot.standard(forHomeDirectory: homeDirectory))
    }

    /// 按给定的扫描根浅扫一次。
    public func discover(scanRoots: [ScanRoot]) -> DiscoveryResult {
        var unreadable: [UnreadableDirectory] = []

        for scanRoot in scanRoots {
            switch shallowEntries(of: scanRoot) {
            case let .failure(directory):
                unreadable.append(directory)
            case let .success(entries):
                // 候选判定在下一步做：先只把扫描根的一级子目录读出来。
                _ = entries
            }
        }

        return DiscoveryResult(candidates: [], unreadableDirectories: unreadable)
    }

    // MARK: - 扫描根列举

    private enum ScanRootOutcome {
        case success([ShallowDirectoryReader.Entry])
        case failure(UnreadableDirectory)
    }

    /// 读一个扫描根的一级子目录，按入口筛选口径过滤。
    ///
    /// 扫描根不存在只是「这里没有可看的东西」（User Story 22），不算读不到；
    /// 读得到但列不出来（权限不足等）才是需要说明的情况。
    private func shallowEntries(of scanRoot: ScanRoot) -> ScanRootOutcome {
        guard ShallowDirectoryReader.isDirectory(scanRoot.path) else { return .success([]) }

        do {
            let entries = try ShallowDirectoryReader.entries(in: scanRoot.path)
            let filtered = entries.filter { entry in
                switch scanRoot.entryFilter {
                case .allEntries:
                    return true
                case .hiddenDirectoriesOnly:
                    return entry.name.hasPrefix(".")
                }
            }
            return .success(filtered)
        } catch {
            return .failure(UnreadableDirectory(path: scanRoot.path, reason: reason(of: error)))
        }
    }

    /// 系统错误的中文说明。
    private func reason(of error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError
            || nsError.code == NSFileReadNoSuchFileError
        else {
            return nsError.localizedDescription
        }
        return nsError.code == NSFileReadNoSuchFileError ? "路径已不存在" : "权限不足"
    }
}
