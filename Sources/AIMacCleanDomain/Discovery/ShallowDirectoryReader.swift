import Foundation

/// 浅扫的目录读取：列举、判型、**不跟随符号链接**。
///
/// 这一层刻意只有一个职责——把「磁盘上有什么」变成值，且不解析任何符号链接
/// （User Story 12：浅扫不跟随符号链接，避免扫描意外遍历到别处的目录树）。
/// 因此所有判型都看条目**自身**的属性，而不是让它解析到目标再判。
///
/// 读磁盘的动作本身由注入的 `DiscoveryFileSystem` 承担（issue #18）：
/// 默认是真实文件系统，测试可以换成记录器来证明「一次发现到底访问了哪些路径」。
struct ShallowDirectoryReader {

    /// 一个一级条目。
    struct Entry {
        let name: String
        let path: String
        let isDirectory: Bool
        let isSymbolicLink: Bool
    }

    /// 背后读磁盘的那一层。文件头读取也走它（issue #18：浅扫的每一次磁盘访问都可注入、可计数）。
    let fileSystem: any DiscoveryFileSystem

    init(fileSystem: any DiscoveryFileSystem = RealDiscoveryFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// 列举一个目录的一级条目；读不到时抛错，由调用方按目录粒度隔离。
    func entries(in directory: String) throws -> [Entry] {
        try fileSystem.entryNames(inDirectory: directory)
            .sorted()
            .map { name in
                let path = directory + "/" + name
                return Entry(
                    name: name,
                    path: path,
                    isDirectory: isDirectory(path),
                    isSymbolicLink: isSymbolicLink(path)
                )
            }
    }

    /// 条目自身是不是目录；符号链接不算目录（它指向哪里不关浅扫的事）。
    func isDirectory(_ path: String) -> Bool {
        type(of: path) == .typeDirectory
    }

    /// 路径自身是不是符号链接。判据是条目的属性类型，不解析目标。
    func isSymbolicLink(_ path: String) -> Bool {
        type(of: path) == .typeSymbolicLink
    }

    private func type(of path: String) -> FileAttributeType? {
        fileSystem.attributes(ofItemAt: path)?[.type] as? FileAttributeType
    }
}
