import Foundation

import AIMacCleanCore

/// 测试用的临时目录夹具。
///
/// 规则（PRD §13 第 3 条、spec #7「测试禁止触碰真实数据目录」）：
/// 所有测试数据只允许写在这里创建的临时目录里，真实 `~/.claude`、`~/.codex`、`~/.cursor`
/// 等目录绝不参与测试。机械化拦截见 issue #14。
final class TemporaryDirectoryFixture {
    /// 本次夹具的根目录。
    let url: URL

    /// 在系统临时目录下创建一个独立目录。
    init(named name: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-mac-clean-tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// 在夹具下创建一个子目录并返回其路径。
    func makeDirectory(_ relativePath: String) throws -> URL {
        let directory = url.appendingPathComponent(relativePath, isDirectory: true)
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
