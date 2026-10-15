import Foundation

import AIMacCleanRules

/// 结构指纹的比对（GLOSSARY「结构指纹」；issue #12 / PRD §4.3）。
///
/// 比对的是规则文件里声明的三类结构特征——会话文件的路径模式、会话目录的形态、
/// 项目目录的存在形态——加上会话文件**开头若干字节**里的字段特征。
///
/// ## 边界（这是本票最大的两个失败模式之一）
///
/// 1. **不参与准入的只有名称**：名称关键词由 `ToolDiscoverer` 单独处理，
///    本类型从头到尾只看路径与文件头，代码里不存在任何工具名字符串。
/// 2. **不跟随符号链接**：遍历时遇到符号链接就跳过，既不判断它指向哪里，
///    也不把它当作目录或会话文件（User Story 12）。
///
/// ## 有界
///
/// 浅扫要在几秒内出结果（User Story 2、44），因此这里既不递归算体积，
/// 也不无限深地走：层数、访问条目数、会话文件命中数、文件头读取字节数都有上限。
enum FingerprintEvaluator {

    /// 单个候选允许的最大相对层数。
    ///
    /// 实测形状里最深的是 Cursor 的 `projects/<编码路径>/agent-transcripts/<uuid>/<uuid>.jsonl`（第 5 层），
    /// 取 6 留一层余量。
    static let maximumDepth = 6

    /// 单个候选允许访问的条目数上限（防止超大目录树把浅扫拖成深扫）。
    static let maximumVisitedEntries = 4_000

    /// 单个候选最多读几个会话文件的头（每个文件最多读 `headerByteLimit` 字节）。
    static let maximumHeaderReads = 3

    /// 自带压缩的扩展名：本阶段不读它们的内容（spec #7 §Out of Scope「不读压缩会话内容」）。
    private static let compressedExtensions = ["zst", "zstd", "gz", "xz", "zip", "bz2", "lz4", "br"]

    /// 比对结果。
    struct Evidence {
        /// 命中的路径类结构指纹（模式串的规范写法），供确认记录留痕。
        ///
        /// 只有它能让目录成为候选：文件头字段特征是佐证，不参与准入。
        var fingerprints: [String] = []
        /// 是否命中了**路径类**结构特征——只有它才能让目录成为候选。
        var hasStructuralMatch: Bool { !fingerprints.isEmpty }
        /// 文件头里实际出现的字段特征（外部佐证的一种）。
        var contentFeatures: [String] = []
    }

    /// 在一个工具根下比对结构指纹。
    ///
    /// - Parameters:
    ///   - toolRootPath: 规则声明的工具根绝对路径。
    ///   - reader: 目录读取器；它背后是可注入的 `DiscoveryFileSystem`（issue #18），
    ///     测试据此断言「一次发现只访问了规则声明的工具根子树」。
    /// - Returns: 命中的结构特征，以及沿途读不到的目录（按目录粒度隔离）。
    static func evaluate(
        fingerprint: StructuralFingerprint,
        toolRootPath: String,
        reader: ShallowDirectoryReader = ShallowDirectoryReader()
    ) -> (evidence: Evidence, unreadable: [UnreadableDirectory]) {
        var evidence = Evidence()
        var unreadable: [UnreadableDirectory] = []
        var visited = 0
        var headerReads = 0
        var pendingSessionFiles: [String] = []

        // 广度优先：浅扫要在几秒内出结果，深度优先会被一个超深的目录拖住。
        var queue: [(path: String, relativePath: String, depth: Int)] = [(toolRootPath, "", 0)]
        var queueIndex = 0

        while queueIndex < queue.count {
            let current = queue[queueIndex]
            queueIndex += 1

            let entries: [ShallowDirectoryReader.Entry]
            do {
                entries = try reader.entries(in: current.path)
            } catch {
                // 权限错误按目录粒度隔离：只影响这个目录，整体扫描继续。
                unreadable.append(UnreadableDirectory(path: current.path, reason: reason(of: error)))
                continue
            }

            for entry in entries {
                visited += 1
                guard visited <= maximumVisitedEntries else { return (evidence, unreadable) }

                // 符号链接一律跳过：不解析、不遍历、不参与匹配。
                guard !entry.isSymbolicLink else { continue }

                let relativePath = current.relativePath.isEmpty
                    ? entry.name
                    : current.relativePath + "/" + entry.name

                if entry.isDirectory {
                    for pattern in fingerprint.sessionDirectoryShapes + fingerprint.projectDirectoryShapes
                    where pattern.matches(relativePath: relativePath) {
                        record(pattern.canonicalString, in: &evidence)
                    }
                    guard current.depth < maximumDepth else { continue }
                    queue.append((entry.path, relativePath, current.depth + 1))
                } else if matches(relativePath, anyOf: fingerprint.sessionFilePatterns) {
                    record(patterns: fingerprint.sessionFilePatterns, matching: relativePath, in: &evidence)
                    if headerReads < maximumHeaderReads,
                       !isCompressed(entry.name),
                       !fingerprint.fileHeaderKeys.isEmpty {
                        pendingSessionFiles.append(entry.path)
                        headerReads += 1
                    }
                }
            }
        }

        // 文件头只读开头若干字节，且只读会话文件（PRD §13 第 3 条）。
        for file in pendingSessionFiles {
            // 读不到返回 `nil`：那是「没有内容特征」，不是「有」。
            guard let header = reader.fileSystem.readHeader(ofFileAt: file, limit: fingerprint.headerByteLimit)
            else { continue }
            evidence.contentFeatures.append(contentsOf: fingerprint.fileHeaderKeys.filter { header.contains($0) })
        }

        return (evidence, unreadable)
    }

    // MARK: - 内部

    private static func matches(_ relativePath: String, anyOf patterns: [PathPattern]) -> Bool {
        patterns.contains { $0.matches(relativePath: relativePath) }
    }

    private static func record(_ fingerprint: String, in evidence: inout Evidence) {
        guard !evidence.fingerprints.contains(fingerprint) else { return }
        evidence.fingerprints.append(fingerprint)
    }

    private static func record(
        patterns: [PathPattern],
        matching relativePath: String,
        in evidence: inout Evidence
    ) {
        for pattern in patterns where pattern.matches(relativePath: relativePath) {
            record(pattern.canonicalString, in: &evidence)
        }
    }

    /// 自带压缩的文件只按扩展名识别，本阶段不解压、不读内容（ADR-0001）。
    static func isCompressed(_ fileName: String) -> Bool {
        guard let dot = fileName.lastIndex(of: ".") else { return false }
        return compressedExtensions.contains(String(fileName[fileName.index(after: dot)...]).lowercased())
    }

    private static func reason(of error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return nsError.localizedDescription }
        switch nsError.code {
        case NSFileReadNoPermissionError: return "权限不足"
        case NSFileReadNoSuchFileError: return "路径已不存在"
        default: return nsError.localizedDescription
        }
    }
}
