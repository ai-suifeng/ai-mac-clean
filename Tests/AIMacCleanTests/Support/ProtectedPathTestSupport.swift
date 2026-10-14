import Foundation

/// 内置受保护清单测试用的临时目录构造工具（issue #9）。
///
/// 与 `TemporaryDirectoryFixture` 分文件放置，避免与其它票并行修改同一文件。
/// 只在 `FileManager.default.temporaryDirectory` 下创建文件与符号链接，
/// 绝不触碰真实的 AI 工具数据目录（PRD §13 第 3 条）。
enum ProtectedPathTestSupport {

    /// 一个形状与真实主目录一致的临时目录树：四个工具根都在里面。
    ///
    /// 目录名照抄 PRD §5.4 的实测形态（`.claude` / `.codex` / `.cursor` /
    /// `Library/Application Support/deepseek-harness-desktop/harness-home`），
    /// 让内置条目既能作用于真实主目录，也能作用于这棵树。
    struct FakeHome {
        let root: URL
        /// 符号链接解析后的主目录。
        var homeDirectory: String { root.resolvingSymlinksInPath().path }

        func toolRoot(_ relativePath: String) -> URL {
            root.appendingPathComponent(relativePath, isDirectory: true)
        }

        var claudeRoot: URL { toolRoot(".claude") }
        var codexRoot: URL { toolRoot(".codex") }
        var cursorRoot: URL { toolRoot(".cursor") }
        var harnessRoot: URL {
            toolRoot("Library/Application Support/deepseek-harness-desktop/harness-home")
        }

        /// 在 `root` 下建出一个与真实主目录同构的目录树。
        static func make(named name: String, fixture: TemporaryDirectoryFixture) throws -> FakeHome {
            let home = FakeHome(root: fixture.url)
            let fileManager = FileManager.default
            for directory in [
                home.claudeRoot,
                home.codexRoot,
                home.cursorRoot,
                home.harnessRoot,
            ] {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            return home
        }
    }

    /// 在某个目录下创建一个占位文件，返回它的路径。
    @discardableResult
    static func createFile(named name: String, in directory: URL) throws -> URL {
        let fileURL = directory.appendingPathComponent(name, isDirectory: false)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: fileURL)
        return fileURL
    }

    /// 在某个目录下创建一个子目录，返回它的路径。
    @discardableResult
    static func createDirectory(named name: String, in directory: URL) throws -> URL {
        let directoryURL = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    /// 在 `directory` 下创建一个名为 `name` 的符号链接，指向 `destination`。
    @discardableResult
    static func createSymbolicLink(named name: String, in directory: URL, pointingTo destination: URL) throws -> URL {
        let linkURL = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: destination)
        return linkURL
    }
}
