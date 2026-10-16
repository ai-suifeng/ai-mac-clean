import Foundation

import AIMacCleanDomain

/// 把一次发现**关进夹具树**：树以外的路径一律当作不存在（issue #19）。
///
/// ## 为什么需要它
///
/// 出厂规则里有**绝对安装路径**（Cursor 的 `/Applications/Cursor.app`、Codex 的
/// `/opt/homebrew/bin/codex`、DeepSeek Harness 的 `/Applications/DeepSeek Harness.app`）。
/// 它们是真实存在的位置，因此在一个只该看临时目录的用例里，「本机装了什么」会顺着
/// 这些 `stat` 渗进置信度：本机装了 Cursor，同一棵夹具树的 Cursor 候选就是「高」，
/// 换一台没装的机器就是「中」。
///
/// 这层包装把那个变量去掉：树外路径读不到，测试结果只由夹具决定。
///
/// ## 它不影响「访问过什么」
///
/// 它只改变**回答**，不改变尝试。要断言访问记录时把它套在记录器**里面**
/// （`RecordingDiscoveryFileSystem(wrapping: ConfinedDiscoveryFileSystem(...))`），
/// 记录器仍然会照记每一次树外的尝试——那正是 issue #19 验收 1 要看的东西。
final class ConfinedDiscoveryFileSystem: DiscoveryFileSystem {

    /// 夹具树的根：只有它自己与它之下算「存在」。
    private let root: String

    private let wrapped: any DiscoveryFileSystem

    init(confinedTo root: String, wrapping wrapped: any DiscoveryFileSystem = RealDiscoveryFileSystem()) {
        self.root = root.hasSuffix("/") ? String(root.dropLast()) : root
        self.wrapped = wrapped
    }

    private func isConfined(_ path: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    func entryNames(inDirectory path: String) throws -> [String] {
        guard isConfined(path) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        }
        return try wrapped.entryNames(inDirectory: path)
    }

    func attributes(ofItemAt path: String) -> [FileAttributeKey: Any]? {
        guard isConfined(path) else { return nil }
        return wrapped.attributes(ofItemAt: path)
    }

    func readHeader(ofFileAt path: String, limit: Int) -> String? {
        guard isConfined(path) else { return nil }
        return wrapped.readHeader(ofFileAt: path, limit: limit)
    }
}
