import Foundation

import AIMacCleanDomain

/// **会记录写尝试**的文件系统替身基类（issue #23 零写入断言的基础设施）。
///
/// 「只展示、不动」是深扫对用户的核心承诺（PRD §5.1、§2.3）。光断言「扫描结果里没有
/// 多出文件」证明不了它——那只说明*这次*没多，证明不了扫描过程**从未试过**写。
/// 因此把「写」本身变成一条可观察记录：基类提供创建 / 覆写 / 移动 / 删除四类写入口，
/// 每次调用先记一笔再真的执行。
///
/// ## 为什么写操作**不失败**
///
/// 只读替身会让写操作失败，于是「扫描没崩」间接暗示「没写过」——但一次被吞掉的失败写
/// 尝试照样能通过那种断言。这里让写**成功**：只要深扫碰过写路径，`writeAttempts`
/// 就一定不为空，「零写入」是被直接看见的，而不是被推断出来的。
///
/// 子类只需实现自己关心的读取记录。
class WriteRecordingDiscoveryFileSystem: DiscoveryFileSystem, @unchecked Sendable {

    /// 一次写尝试的种类。
    enum WriteAttempt: Equatable, CustomStringConvertible {
        /// 在 `at` 创建目录。
        case createDirectory(String)
        /// 把 `bytes` 字节写到 `at`。
        case writeFile(String, bytes: Int)
        /// 把 `from` 移到 `to`。
        case move(String, String)
        /// 删掉 `at`。
        case remove(String)

        var description: String {
            switch self {
            case let .createDirectory(path): return "创建目录 \(path)"
            case let .writeFile(path, bytes): return "写入 \(path)（\(bytes) 字节）"
            case let .move(from, to): return "移动 \(from) → \(to)"
            case let .remove(path): return "删除 \(path)"
            }
        }
    }

    /// 被包装的真实文件系统；本类**不**伪造它的任何回答。
    let wrapped: any DiscoveryFileSystem

    private let writeLock = NSLock()
    private var recordedWrites: [WriteAttempt] = []

    init(wrapping wrapped: any DiscoveryFileSystem = RealDiscoveryFileSystem()) {
        self.wrapped = wrapped
    }

    /// 到目前为止的每一次写尝试（保持发生顺序）。
    var writeAttempts: [WriteAttempt] {
        writeLock.lock()
        defer { writeLock.unlock() }
        return recordedWrites
    }

    /// 断言失败时用的有界摘要：零写入时就是一句「没有任何写尝试」。
    var writeSummary: String {
        let attempts = writeAttempts
        guard !attempts.isEmpty else { return "零写入（没有任何写尝试）" }
        return attempts.map(\.description).joined(separator: "\n")
    }

    func resetWrites() {
        writeLock.lock()
        defer { writeLock.unlock() }
        recordedWrites.removeAll()
    }

    // MARK: - 写操作（本类型存在的理由：让它们可被看见）

    func createDirectory(atPath path: String) throws {
        record(.createDirectory(path))
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func writeFile(atPath path: String, contents: Data) throws {
        record(.writeFile(path, bytes: contents.count))
        try contents.write(to: URL(fileURLWithPath: path))
    }

    func moveItem(atPath path: String, toPath destination: String) throws {
        record(.move(path, destination))
        try FileManager.default.moveItem(atPath: path, toPath: destination)
    }

    func removeItem(atPath path: String) throws {
        record(.remove(path))
        try FileManager.default.removeItem(atPath: path)
    }

    private func record(_ attempt: WriteAttempt) {
        writeLock.lock()
        defer { writeLock.unlock() }
        recordedWrites.append(attempt)
    }

    // MARK: - DiscoveryFileSystem（只读部分交给子类）

    func entryNames(inDirectory path: String) throws -> [String] {
        try wrapped.entryNames(inDirectory: path)
    }

    func attributes(ofItemAt path: String) -> [FileAttributeKey: Any]? {
        wrapped.attributes(ofItemAt: path)
    }

    func readHeader(ofFileAt path: String, limit: Int) -> String? {
        wrapped.readHeader(ofFileAt: path, limit: limit)
    }

    func symbolicLinkDestination(atPath path: String) -> String? {
        wrapped.symbolicLinkDestination(atPath: path)
    }
}
