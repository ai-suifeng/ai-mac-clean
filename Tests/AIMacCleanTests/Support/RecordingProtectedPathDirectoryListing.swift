import Foundation

import AIMacCleanRules

/// 记录受保护判定做过哪些目录列举（issue #19）。
///
/// 受保护判定要为 `skills*` 这类目录模式做通配展开。展开本身是允许的——**但只允许
/// 发生在规则声明的工具根内部**；列举主目录（`~/.claude.json` 这类主目录条目的旧实现）
/// 正是 user 第二次反馈的缺陷。装上这个记录器，这件事就能被逐条断言。
///
/// 它是真实的列举，只是把每一次记下来：不是伪造文件系统，因此记录到的就是真实做过的事。
final class RecordingProtectedPathDirectoryListing: ProtectedPathDirectoryListing {

    private let wrapped: any ProtectedPathDirectoryListing

    /// 按发生顺序记下的每次列举。
    private(set) var listedDirectories: [String] = []

    init(wrapping wrapped: any ProtectedPathDirectoryListing = RealProtectedPathDirectoryListing()) {
        self.wrapped = wrapped
    }

    func entryNames(inDirectory path: String) -> [String]? {
        listedDirectories.append(path)
        return wrapped.entryNames(inDirectory: path)
    }
}
