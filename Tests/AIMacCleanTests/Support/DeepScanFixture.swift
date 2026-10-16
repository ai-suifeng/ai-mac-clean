import Foundation

import AIMacCleanDomain
import AIMacCleanRules

/// 深扫用例的夹具（issue #23）。
///
/// 形状照抄 PRD §14 的实测结论：`.zst`/`.zstd` 与明文并存、扁平 `archived_sessions/`、
/// `agent-transcripts/`、双横线编码、`*-bak` 干扰目录、指向外部的符号链接、
/// 零字节文件与空目录。**真实数据目录绝不参与**——夹具根一律走
/// `TemporaryDirectoryFixture`（issue #14 的护栏在那一层拦）。
///
/// 顺带把「写文件」这件事做成夹具自己的方法：这样深扫用例里出现 `AuditorFileSystem`
/// 时，「写尝试」只可能来自被测代码，不会与夹具备料混在一起。
final class DeepScanFixture {

    let directory: TemporaryDirectoryFixture

    var root: URL { directory.url }
    var rootPath: String { directory.url.path }

    init(named name: String) throws {
        directory = try TemporaryDirectoryFixture(named: "deep-scan-\(name)")
    }

    func remove() {
        directory.remove()
    }

    // MARK: - 备料

    /// 写一个**精确字节数**的文件（`1 KB + 37` 这种数才能暴露逐级取整的错）。
    @discardableResult
    func write(_ relativePath: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func write(_ relativePath: String, text: String) throws -> URL {
        try write(relativePath, bytes: Data(text.utf8).count)
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 建一个符号链接。`relativePath` 是链接自身的位置，`destination` 原样传给 `ln -s`。
    @discardableResult
    func makeSymbolicLink(_ relativePath: String, to destination: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url
    }

    // MARK: - 工具

    /// 一台工具：工具根 + 已准入的规则 + 用于断言的展示名。
    struct Tool {
        let displayName: String
        let rootPath: String
        /// 规则里声明的**仅展示**根（issue #31）的绝对路径：`~/…` 展开到夹具根。
        let displayOnlyRootPaths: [String]
        let rule: ToolRule
        let requested: ConfirmedTool
    }

    /// 声明一台以 `relativeRoot`（相对夹具根）为工具根的工具。
    ///
    /// `classificationJSON` 是分类条目的 JSON 数组片段，例如
    /// `["{\"pattern\": \"projects/**\", \"category\": \"archivableSession\"}"]`。
    ///
    /// `displayOnlyRelativeRoots` 是规则里**仅展示根**的相对位置（issue #31）：
    /// 写成 `~/…` 声明，与出厂规则（Cursor AppSupport、Harness 的 Electron profile）
    /// 同一套写法——深扫因此要自己把 `~/` 展开到 `homeDirectory`。
    func tool(
        id: String,
        displayName: String,
        relativeRoot: String,
        displayOnlyRelativeRoots: [String] = [],
        classificationJSON: [String] = []
    ) throws -> Tool {
        let absoluteRoot = root.appendingPathComponent(relativeRoot).path
        let classification = classificationJSON.isEmpty ? "" : ",\n    \"classification\": [\n      " +
            classificationJSON.joined(separator: ",\n      ") + "\n    ]"
        var rootDeclarations = ["{ \"path\": \"\(absoluteRoot)\", \"role\": \"toolRoot\" }"]
        rootDeclarations += displayOnlyRelativeRoots.map { "{ \"path\": \"~/\($0)\", \"role\": \"displayOnly\" }" }

        let json = """
        {
          "schemaVersion": 1,
          "id": "\(id)",
          "displayName": "\(displayName)",
          "roots": [\(rootDeclarations.joined(separator: ", "))]\(classification)
        }
        """

        let rule = try RuleLoader.loadRule(from: Data(json.utf8), source: "深扫夹具规则 \(id)")
        let report = RuleSetAdmission.admit(rules: [rule], homeDirectory: rootPath)
        guard report.rejections.isEmpty, let usable = report.usableRules.first else {
            throw DeepScanFixtureError.ruleRejected(id: id, reasons: report.rejections.map(\.reason.description))
        }

        return Tool(
            displayName: displayName,
            rootPath: absoluteRoot,
            displayOnlyRootPaths: displayOnlyRelativeRoots.map { rootPath + "/" + $0 },
            rule: usable,
            requested: ConfirmedTool(id: id, displayName: displayName, toolRootPath: absoluteRoot)
        )
    }

    /// 一台工具的扫描输入。
    func confirmed(_ tool: Tool) -> ConfirmedTool { tool.requested }

    /// 该工具的扫描输入与规则一一对应，便于断言「按工具分类」。
    func scanInputs(_ tools: [Tool]) -> [ConfirmedTool] { tools.map(\.requested) }
}

enum DeepScanFixtureError: Error, CustomStringConvertible {
    case ruleRejected(id: String, reasons: [String])

    var description: String {
        switch self {
        case let .ruleRejected(id, reasons):
            return "深扫夹具规则 \(id) 没通过规则集准入：\(reasons.joined(separator: "；"))"
        }
    }
}
