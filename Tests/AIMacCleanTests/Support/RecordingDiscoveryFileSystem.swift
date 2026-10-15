import Foundation

import AIMacCleanDomain

/// **记录磁盘读取的** `DiscoveryFileSystem`（issue #18）。
///
/// 它是真实的文件系统，只是把每一次读取都记下来。存在的理由很具体：
/// 候选列表只能证明「没有多报」，证明不了「没有多看」——而浅扫对用户的承诺恰恰是
/// 「只碰 AI 工具的数据目录」。装上这个记录器，就能断言一次发现**访问了哪些路径、
/// 访问了多少次**，把「不枚举通用位置」从承诺变成可测的事实。
///
/// ## 它不是什么
///
/// 不是伪造文件系统：所有读取都真的落到磁盘上，因此记录到的就是浅扫真实做过的事。
/// 失败与空结果的区别也原样保留——读不到就是抛错。
final class RecordingDiscoveryFileSystem: DiscoveryFileSystem {

    /// 底层真实文件系统；本类**不**伪造它的任何回答。
    private let wrapped: any DiscoveryFileSystem

    /// 一次读取的种类。四类分开记，是因为「列举了无关目录」与「读了一个会话文件头」
    /// 是两种完全不同的越界（前者是范围问题，后者是只读元数据的问题）。
    enum Access: Equatable, CustomStringConvertible {
        /// 列举某个目录的一级条目。
        case listed(String)
        /// 读某个路径**自身**的属性（不解析符号链接）。
        case stat(String)
        /// 读某个文件的开头若干字节。
        case header(String)

        var path: String {
            switch self {
            case let .listed(path), let .stat(path), let .header(path): return path
            }
        }

        var description: String {
            switch self {
            case let .listed(path): return "列举 \(path)"
            case let .stat(path): return "查属性 \(path)"
            case let .header(path): return "读文件头 \(path)"
            }
        }
    }

    /// 按发生顺序记下的每一次读取。
    private(set) var accesses: [Access] = []

    init(wrapping wrapped: any DiscoveryFileSystem = RealDiscoveryFileSystem()) {
        self.wrapped = wrapped
    }

    // MARK: - 断言用的查询

    /// 每次读取都碰过的路径（去重、保持首次出现顺序）。
    var touchedPaths: [String] {
        var seen: Set<String> = []
        return accesses.map(\.path).filter { seen.insert($0).inserted }
    }

    /// 被列举过的目录（去重、保持首次出现顺序）。
    var listedDirectories: [String] {
        var seen: Set<String> = []
        return accesses.compactMap { access -> String? in
            guard case let .listed(path) = access, seen.insert(path).inserted else { return nil }
            return path
        }
    }

    /// 碰过某个前缀下的任何路径（含前缀本身）。
    func touched(underOrEqual prefix: String) -> [Access] {
        let normalized = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        return accesses.filter { $0.path == normalized || $0.path.hasPrefix(normalized + "/") }
    }

    /// 碰过某个前缀下的任何路径（不含前缀本身）。
    func touched(under prefix: String) -> [Access] {
        let normalized = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        return accesses.filter { $0.path.hasPrefix(normalized + "/") }
    }

    func reset() {
        accesses.removeAll()
    }

    /// 访问记录的**有界**摘要。断言失败时直接打 `accesses` 会刷出上千行，
    /// 真正要看的是「碰了哪些位置、碰了多少次」。
    var summary: String {
        var lines: [String] = []
        for directory in listedDirectories {
            lines.append("列举 \(directory)（该位置下共 \(touched(underOrEqual: directory).count) 次访问）")
        }
        let headerCount = accesses.filter { access in
            if case .header = access { return true }
            return false
        }.count
        lines.append("读文件头 \(headerCount) 次")
        return lines.joined(separator: "\n")
    }

    /// 把访问记录里的 `prefix` 换成 `~`，便于跨两棵夹具树比较（临时目录名各不相同）。
    func abbreviating(_ prefix: String) -> [Access] {
        let normalized = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        return accesses.map { access in
            func replace(_ path: String) -> String {
                path == normalized
                    ? "~"
                    : (path.hasPrefix(normalized + "/") ? "~" + String(path.dropFirst(normalized.count)) : path)
            }
            switch access {
            case let .listed(path): return .listed(replace(path))
            case let .stat(path): return .stat(replace(path))
            case let .header(path): return .header(replace(path))
            }
        }
    }

    // MARK: - DiscoveryFileSystem

    func entryNames(inDirectory path: String) throws -> [String] {
        accesses.append(.listed(path))
        return try wrapped.entryNames(inDirectory: path)
    }

    func attributes(ofItemAt path: String) -> [FileAttributeKey: Any]? {
        accesses.append(.stat(path))
        return wrapped.attributes(ofItemAt: path)
    }

    func readHeader(ofFileAt path: String, limit: Int) -> String? {
        accesses.append(.header(path))
        return wrapped.readHeader(ofFileAt: path, limit: limit)
    }
}
