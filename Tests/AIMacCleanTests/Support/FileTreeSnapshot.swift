import Foundation

/// 一棵目录树的**逐条元数据快照**：路径 + 类型 + 大小 + 修改时间 + 链接目标。
///
/// 深扫的零写入承诺此前只由 `WriteRecordingDiscoveryFileSystem.writeAttempts == []` 断言，
/// 而那条记录在接口上根本不可达（`DiscoveryFileSystem` 只有读取入口）——于是那条断言
/// 永远不会失败，是句空话（review 发现 4）。
///
/// 这里换一条**不依赖被测代码自觉报告**的证明：扫描前后各拍一张整棵树的快照，
/// 逐字段要求完全一致，树上的任何新增 / 删除 / 改名 / 写字节 / 改链接都会让它失败。
///
/// 快照本身也得被证明不是空话：`DeepScanZeroWriteTests.test快照能发现树上的任何变化`
/// 会真的改动树并断言快照不同。
///
/// 只读元数据、只做 `lstat`（不跟随符号链接）：对链接只记它自己的类型与目标。
struct FileTreeSnapshot: Equatable, CustomStringConvertible {

    /// 一个条目的快照。
    struct Entry: Equatable, CustomStringConvertible {

        /// 条目自身的类型（`file` / `directory` / `symbolicLink` / …）。
        let kind: String

        /// 字节数（目录与链接也有大小，照 `lstat` 原样记）。
        let bytes: Int64?

        /// 修改时间。
        let modified: Date?

        /// 符号链接的目标；不是链接时为 `nil`。
        let linkDestination: String?

        var description: String {
            var parts = [kind, bytes.map { "\($0) B" } ?? "大小不可知"]
            if let modified { parts.append("mtime \(modified.timeIntervalSince1970)") }
            if let linkDestination { parts.append("→ \(linkDestination)") }
            return parts.joined(separator: "，")
        }
    }

    /// 相对快照根（`""` 是根本身）的路径 → 条目。
    let entries: [String: Entry]

    /// 拍一张 `root` 下整棵树（含根）的快照。
    static func capture(root: String) throws -> FileTreeSnapshot {
        var entries: [String: Entry] = [:]

        func record(_ relativePath: String, at path: String) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let type = attributes[.type] as? FileAttributeType
            let isLink = type == .typeSymbolicLink
            entries[relativePath] = Entry(
                kind: name(of: type),
                bytes: (attributes[.size] as? NSNumber)?.int64Value,
                modified: attributes[.modificationDate] as? Date,
                linkDestination: isLink
                    ? try? FileManager.default.destinationOfSymbolicLink(atPath: path)
                    : nil
            )

            // 只有**真目录**才往下走：链接（哪怕是链接到目录）绝不跟随。
            guard type == .typeDirectory else { return }
            for name in try FileManager.default.contentsOfDirectory(atPath: path).sorted() {
                let childPath = path.hasSuffix("/") ? path + name : path + "/" + name
                try record(relativePath.isEmpty ? name : relativePath + "/" + name, at: childPath)
            }
        }

        try record("", at: root)
        return FileTreeSnapshot(entries: entries)
    }

    private static func name(of type: FileAttributeType?) -> String {
        switch type {
        case .typeRegular: return "file"
        case .typeDirectory: return "directory"
        case .typeSymbolicLink: return "symbolicLink"
        case .typeCharacterSpecial: return "characterSpecial"
        case .typeBlockSpecial: return "blockSpecial"
        case .typeSocket: return "socket"
        default: return "unknown"
        }
    }

    /// 逐条列出（路径排序），断言失败时能直接看出是哪一条变了。
    var description: String {
        entries
            .sorted { $0.key < $1.key }
            .map { "\($0.key.isEmpty ? "." : $0.key)：\($0.value)" }
            .joined(separator: "\n")
    }
}
