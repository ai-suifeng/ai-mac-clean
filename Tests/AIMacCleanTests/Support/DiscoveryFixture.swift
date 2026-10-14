import Foundation

import XCTest

/// 发现管线的测试夹具：一棵假的 `$HOME` 目录树。
///
/// 形状照抄 PRD §14 的本机实测结论（spec #7「构造数据的纪律」第 2 条），
/// 而不是照抄更早的 PRD §5.4 描述：Claude Code 新版没有 `file-history/`、
/// `todos/`、`statsig/`，文件历史以 `file-history-snapshot` 内联在转录里。
/// `*.zst` 与明文 `.jsonl` 并存、`archived_sessions/` 扁平存放等实测形状都在这里。
///
/// 全部数据只落在临时目录，真实 `~/.claude`、`~/.codex` 等目录绝不参与
/// （PRD §13 第 3 条；机械化拦截见 issue #14 与 `TemporaryDirectoryFixture`）。
final class DiscoveryFixture {

    /// 假的 `$HOME`。
    let home: TemporaryDirectoryFixture

    init(named name: String = "discovery") throws {
        home = try TemporaryDirectoryFixture(named: name)
    }

    /// 本次夹具的假主目录绝对路径。
    var homePath: String { home.url.path }

    /// 在假主目录下建目录。
    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> String {
        try home.makeDirectory(relativePath).path
    }

    /// 在假主目录下建文件，自动补齐父目录。
    ///
    /// - Parameter contents: 文件内容。默认给一行带 JSON 字段的转录首行，
    ///   这样「只读文件头若干字节」的内容特征在夹具里是**真的**成立的。
    @discardableResult
    func makeFile(_ relativePath: String, contents: String = DiscoveryFixture.sampleTranscriptLine) throws -> String {
        let url = home.url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// 建一个**指向夹具外部**的符号链接（PRD §14.5 的链接形态）。
    @discardableResult
    func makeSymbolicLink(_ relativePath: String, pointingTo destination: String) throws -> String {
        let url = home.url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url.path
    }

    /// 把某个目录的权限收干，用来构造「无权访问」（PRD §4.4、User Story 14）。
    func denyAccess(toRelativePath relativePath: String) throws {
        let url = home.url.appendingPathComponent(relativePath)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
    }

    /// 恢复目录权限，供 `tearDown` 清理（夹具删除失败不该让整轮测试失败）。
    func restoreAccess(toRelativePath relativePath: String) {
        let url = home.url.appendingPathComponent(relativePath)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// 一行「像会话转录」的 JSONL 首行：含规则声明的字段特征。
    static let sampleTranscriptLine = #"{"type":"user","message":{"role":"user","content":"hello"}}"# + "\n"

    /// OpenCode 的规则夹具：藏在 `~/.local/share/opencode` 的非标准位置（User Story 7）。
    ///
    /// PRD §5.4 没有给出 OpenCode 的实测目录形状（它的格式是私有协议与 SQLite，
    /// 第一期只做发现与占用展示）。因此这里只声明一条保守的会话文件路径模式：
    /// 本切片要证明的是**位置能被发现**，不是断言某个具体内部结构。
    static let openCodeJSON = """
    {
      "schemaVersion": 1,
      "id": "opencode",
      "displayName": "OpenCode",
      "roots": [
        { "path": "~/.local/share/opencode", "role": "toolRoot" }
      ],
      "structuralFingerprint": {
        "sessionFilePatterns": ["storage/<encodedPath>/session/message/<uuid>.json"],
        "projectDirectoryShapes": ["storage/<encodedPath>"]
      },
      "classification": [
        { "pattern": "storage/<encodedPath>/session/message/<uuid>.json", "category": "archivableSession" },
        { "pattern": "storage/**", "category": "uncertain" }
      ],
      "selfCompressed": false
    }
    """
}
