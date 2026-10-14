import Foundation

import AIMacCleanCore

/// 测试数据落到了真实 AI 工具数据目录下（issue #14 护栏在夹具这一层的拦截）。
enum TemporaryDirectoryFixtureError: Error, CustomStringConvertible {
    case forbiddenLocation(path: String, root: String)

    var description: String {
        switch self {
        case let .forbiddenLocation(path, root):
            return "拒绝在真实 AI 工具数据目录 \(root) 下建测试夹具：\(path)"
        }
    }
}

/// 测试用的临时目录夹具。
///
/// 规则（PRD §13 第 3 条、spec #7「测试禁止触碰真实数据目录」）：
/// 所有测试数据只允许写在这里创建的临时目录里，真实 `~/.claude`、`~/.codex`、`~/.cursor`
/// 等目录绝不参与测试。机械化拦截见 issue #14。
final class TemporaryDirectoryFixture {
    /// 本次夹具的根目录。
    let url: URL

    /// 在系统临时目录下创建一个独立目录。
    ///
    /// - Parameter baseDirectory: 夹具落地基址，默认系统临时目录。即使传入自定义基址，
    ///   也要先过护栏：`TMPDIR` 被指到真实工具目录时必须拒绝，而不是照建不误。
    init(named name: String, baseDirectory: URL? = nil) throws {
        let base = (baseDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("ai-mac-clean-tests", isDirectory: true)
        let root = base.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)

        if let violation = RealToolDirectoryGuard.live.violation(forPath: root.path) {
            throw TemporaryDirectoryFixtureError.forbiddenLocation(
                path: root.path,
                root: violation.root.homeRelativePath
            )
        }

        url = root
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// 在夹具下创建一个子目录并返回其路径。
    func makeDirectory(_ relativePath: String) throws -> URL {
        let directory = url.appendingPathComponent(relativePath, isDirectory: true)
        if let violation = RealToolDirectoryGuard.live.violation(forPath: directory.path) {
            throw TemporaryDirectoryFixtureError.forbiddenLocation(
                path: directory.path,
                root: violation.root.homeRelativePath
            )
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 递归删除整个夹具。
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    deinit {
        remove()
    }
}
