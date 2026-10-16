import Foundation

import AIMacCleanDomain
import AIMacCleanRules

/// 规模夹具：一棵**可配置的合成大树**（issue #29）。
///
/// 规模要求来自 PRD §14 的实测：`~/.codex/.tmp` 一处 **24,849 个文件**、单个 Codex
/// 会话 **2.38 GiB**、单行最长 **19.4 MB**、总量约 **31 G**。这里建的是同样的**形状**，
/// 不是同样的落盘字节：
///
/// - 大量小文件铺在多层嵌套目录里（`.tmp/<分片>/<桶>/<文件名>`），目录数、每层文件数
///   都可配置——50,000 个文件全塞进一个目录与铺成 50 个目录，对扫描器是两种压力。
/// - 少量大文件用 `ftruncate` 造成**稀疏文件**：逻辑字节数与写满完全一致，而深扫
///   只读元数据（PRD §10、`DeepScanner` 硬纪律 2），因此逻辑大小就是要断言的量；
///   落盘占用可以忽略，50 G 量级的树才能在 CI 里秒级建好。
///
/// ## 清单是**独立**的期望值
///
/// `manifest` 里的字节数与文件数由**构建参数**直接算出（不是再扫一遍得到的），
/// 因此拿它做断言不构成「用算法验证算法」的空转断言（tdd 的 tautological 反模式）。
final class ScaleTreeFixture {

    let directory: TemporaryDirectoryFixture

    var root: URL { directory.url }
    var rootPath: String { directory.url.path }

    init(named name: String) throws {
        directory = try TemporaryDirectoryFixture(named: "scale-\(name)")
    }

    func remove() {
        directory.remove()
    }

    // MARK: - 构建参数

    /// 一棵树的形状。
    struct Shape {

        /// 工具标识（与内置受保护清单的作用域对齐：`.codex` → `codex-cli`）。
        var toolID: String = "codex-cli"

        /// 工具根相对夹具根的位置。用 `.codex` 是为了让内置受保护条目真的参与判定
        /// （PRD §14 的真实形状），而不是一棵「什么规则都命中不了」的干净树。
        var toolRootName: String = ".codex"

        /// 分片目录数（`.tmp/<分片>`）。
        var shardCount: Int = 50

        /// 每个分片下的桶目录数（`.tmp/<分片>/<桶>`）。
        var bucketsPerShard: Int = 1

        /// 每个桶里的小文件数。
        var smallFilesPerBucket: Int = 1_000

        /// 每个小文件的字节数。
        var smallFileBytes: Int = 100

        /// 稀疏大文件：相对工具根的路径 → 逻辑字节数。
        var largeFiles: [(relativePath: String, bytes: Int64)] = [
            (relativePath: "sessions/2026/10/15/rollout-4f0f.jsonl.zst", bytes: 2_553_000_000),
            (relativePath: "sessions/2026/10/15/rollout-huge-line.jsonl", bytes: 19_400_000),
            (relativePath: ".tmp/big.bin", bytes: 879_000_000),
        ]

        /// 小文件总数。
        var smallFileCount: Int { shardCount * bucketsPerShard * smallFilesPerBucket }

        /// 小文件总字节数。
        var smallBytes: Int64 { Int64(smallFileCount) * Int64(smallFileBytes) }

        /// 大文件总字节数。
        var largeBytes: Int64 { largeFiles.reduce(0) { $0 + $1.bytes } }

        /// 树的文件总数（小文件 + 大文件）。
        var totalFileCount: Int { smallFileCount + largeFiles.count }

        /// 树的逻辑总字节数。
        var totalBytes: Int64 { smallBytes + largeBytes }
    }

    /// 建树之后拿到的**独立清单**：期望的文件数与字节数按类分好。
    struct Manifest {
        let shape: Shape

        /// `.tmp/**`（规则声明为缓存与日志）下的小文件字节数（不含稀疏大文件）。
        let cacheSmallBytes: Int64
        /// `.tmp/big.bin` 这类声明覆盖到的稀疏大文件字节数。
        let cacheLargeBytes: Int64
        /// `sessions/**`（规则声明为可归档会话）下的字节数。
        let sessionBytes: Int64

        var cacheBytes: Int64 { cacheSmallBytes + cacheLargeBytes }

        /// `sessions/**` 下的文件数（稀疏大文件里路径以 `sessions/` 开头的那些）。
        var sessionFileCount: Int {
            shape.largeFiles.filter { $0.relativePath.hasPrefix("sessions/") }.count
        }

        /// `.tmp/**` 下的文件数：全部小文件 + 其余稀疏大文件。
        var cacheFileCount: Int {
            shape.smallFileCount + shape.largeFiles.filter { !$0.relativePath.hasPrefix("sessions/") }.count
        }
    }

    // MARK: - 建树

    /// 按形状建树，返回独立清单。
    ///
    /// 建目录与建文件一律走 POSIX `open`/`mkdir`（`FileManager.createDirectory` 只用于
    /// 批量建目录）：50,000 个文件的建树开销必须远小于被测的扫描开销，否则夹具本身
    /// 就成了瓶颈，规模测试会被误判成「扫描慢」。
    @discardableResult
    func build(_ shape: Shape) throws -> Manifest {
        let toolRoot = root.appendingPathComponent(shape.toolRootName)
        try FileManager.default.createDirectory(at: toolRoot, withIntermediateDirectories: true)

        var cacheSmallBytes: Int64 = 0
        let bytesPerSmallFile = shape.smallFileBytes
        let smallFileData = Data(repeating: 0x41, count: bytesPerSmallFile)

        for shard in 0..<shape.shardCount {
            let shardPath = toolRoot
                .appendingPathComponent(".tmp")
                .appendingPathComponent(String(format: "shard-%03d", shard))
            for bucket in 0..<shape.bucketsPerShard {
                let bucketPath = shardPath.appendingPathComponent(String(format: "bucket-%02d", bucket))
                try FileManager.default.createDirectory(at: bucketPath, withIntermediateDirectories: true)
                let bucketString = bucketPath.path
                for file in 0..<shape.smallFilesPerBucket {
                    let name = String(format: "%06d.jsonl", file)
                    try Self.writeFile(atPath: bucketString + "/" + name, bytes: smallFileData)
                }
                cacheSmallBytes += Int64(shape.smallFilesPerBucket) * Int64(bytesPerSmallFile)
            }
        }

        var cacheLargeBytes: Int64 = 0
        var sessionBytes: Int64 = 0
        for large in shape.largeFiles {
            let path = toolRoot.appendingPathComponent(large.relativePath)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.writeSparseFile(atPath: path.path, bytes: large.bytes)
            if large.relativePath.hasPrefix("sessions/") {
                sessionBytes += large.bytes
            } else {
                cacheLargeBytes += large.bytes
            }
        }

        return Manifest(
            shape: shape,
            cacheSmallBytes: cacheSmallBytes,
            cacheLargeBytes: cacheLargeBytes,
            sessionBytes: sessionBytes
        )
    }

    // MARK: - 额外的树形状（链接、读不到的目录、补几个文件）

    /// 写一个精确字节数的小文件（夹具自己的写入口，便于用例摆出受保护 / 外部的形状）。
    @discardableResult
    func write(_ relativePath: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 建一个符号链接；`destination` 原样交给 `FileManager`（可以是绝对路径）。
    @discardableResult
    func makeSymbolicLink(_ relativePath: String, to destination: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url
    }

    /// 把一个目录的权限设成 `000`（造一个**读不到**的目录）；返回它的 URL 便于恢复。
    ///
    /// 权限错误必须是真实的：只有真实文件系统才会在 `entryNames` 上抛错，
    /// 而「按目录粒度隔离」正是要证明这件事（PRD §4.4）。
    @discardableResult
    func lockDirectory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        return url
    }

    /// 恢复目录权限（读得到的目录才能被删掉）。
    func unlock(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// 工具根内**全部条目**的路径（目录 + 文件 + 链接自身），自己递归枚举：
    /// 不跟随符号链接（`FileManager.enumerator` 会跟着链接进目录，那会把链接目标算进来），
    /// 也不读元数据之外的任何东西。
    ///
    /// 它是「深扫应该读哪些路径」的**独立**期望值：用例据此断言「每个条目恰好读一次」，
    /// 而不是拿扫描器自己的输出当基准。
    func entryPaths(underToolRootRelative relativePath: String) -> [String] {
        var paths: [String] = []
        var pending = [root.appendingPathComponent(relativePath).path]
        while let directory = pending.popLast() {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for name in names {
                let path = directory + "/" + name
                paths.append(path)
                let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
                if type == .typeDirectory { pending.append(path) }
            }
        }
        return paths
    }

    // MARK: - 工具与规则

    /// 一棵树对应的「一台已确认工具 + 已准入规则」。
    ///
    /// 分类条目与 PRD §14 的真实形状一致：`sessions/**` 可归档会话、`.tmp/**` 缓存与日志；
    /// 其余一切（含 `.tmp` 之外没被声明的路径）**不声明**——未声明落进不确定，
    /// 深扫绝不默认算作可归档。
    func tool(for shape: Shape) throws -> (tool: ConfirmedTool, rule: ToolRule) {
        let absoluteRoot = root.appendingPathComponent(shape.toolRootName).path
        let json = """
        {
          "schemaVersion": 1,
          "id": "\(shape.toolID)",
          "displayName": "Codex CLI",
          "roots": [{ "path": "\(absoluteRoot)", "role": "toolRoot" }],
          "classification": [
            { "pattern": "sessions/**", "category": "archivableSession" },
            { "pattern": ".tmp/**", "category": "cacheAndLog" }
          ]
        }
        """
        let rule = try RuleLoader.loadRule(from: Data(json.utf8), source: "规模夹具规则 \(shape.toolID)")
        let report = RuleSetAdmission.admit(rules: [rule], homeDirectory: rootPath)
        guard report.rejections.isEmpty, let usable = report.usableRules.first else {
            throw ScaleTreeFixtureError.ruleRejected(reasons: report.rejections.map(\.reason.description))
        }
        let confirmed = ConfirmedTool(id: shape.toolID, displayName: "Codex CLI", toolRootPath: absoluteRoot)
        return (confirmed, usable)
    }

    // MARK: - 建文件

    /// 写一个小文件（协作式：一次 `open` + 一次 `write` + 一次 `close`）。
    private static func writeFile(atPath path: String, bytes: Data) throws {
        let descriptor = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard descriptor >= 0 else {
            throw ScaleTreeFixtureError.fileCreationFailed(path: path, errno: errno)
        }
        defer { close(descriptor) }
        try bytes.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                guard result > 0 else {
                    throw ScaleTreeFixtureError.fileCreationFailed(path: path, errno: errno)
                }
                written += result
            }
        }
    }

    /// 造一个**稀疏**大文件：只设置逻辑长度，不落实际数据块。
    ///
    /// 深扫只读元数据，`ftruncate` 之后的 `st_size` 与写满同样大小完全一样。
    private static func writeSparseFile(atPath path: String, bytes: Int64) throws {
        let descriptor = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard descriptor >= 0 else {
            throw ScaleTreeFixtureError.fileCreationFailed(path: path, errno: errno)
        }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(bytes)) == 0 else {
            throw ScaleTreeFixtureError.fileCreationFailed(path: path, errno: errno)
        }
    }
}

enum ScaleTreeFixtureError: Error, CustomStringConvertible {
    case ruleRejected(reasons: [String])
    case fileCreationFailed(path: String, errno: Int32)

    var description: String {
        switch self {
        case let .ruleRejected(reasons):
            return "规模夹具规则没通过规则集准入：\(reasons.joined(separator: "；"))"
        case let .fileCreationFailed(path, code):
            return "规模夹具建不了文件 \(path)（errno \(code)：\(String(cString: strerror(code))))"
        }
    }
}
