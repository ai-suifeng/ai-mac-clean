import Darwin
import Foundation

import AIMacCleanDomain
import XCTest

/// issue #29：深扫逐文件读取的**窄入口**（大小 + 类型）。
///
/// 深扫每个文件只需要两件事：多大、是什么。走 `attributes(ofItemAt:)` 时 Foundation 会为
/// 每个文件构造整本属性字典——本机实测 **64µs/次**，而同样一次 `lstat` 只要 **3.8µs/次**；
/// 5 万文件里这一项就是 3 秒。因此接缝上加一个只说这两件事的入口：
///
/// - 默认实现退回 `attributes(ofItemAt:)`，于是所有既有替身（记录器、审计器、并发探针）
///   **一行都不用改**，记录器照样把这次读取记成 `stat`；
/// - `RealDiscoveryFileSystem` 用一次 `lstat` 直接回答。
///
/// 两条路必须**逐项一致**，否则「快」就成了「换了另一套判定」。本组用例把这件事钉住：
/// 文件、目录、符号链接、空文件、稀疏大文件、FIFO、Unix 套接字、字符设备逐一对照。
final class ItemMetadataSeamTests: XCTestCase {

    func test窄入口与属性字典在各类条目上逐项一致() throws {
        let fixture = try TemporaryDirectoryFixture(named: "metadata-parity")
        defer { fixture.remove() }

        let fileManager = FileManager.default
        let file = fixture.url.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: file)

        let empty = fixture.url.appendingPathComponent("empty.bin")
        fileManager.createFile(atPath: empty.path, contents: Data())

        let directory = try fixture.makeDirectory("subdir")

        let link = fixture.url.appendingPathComponent("link")
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: file.path)

        // 稀疏大文件：逻辑大小与写满一致（深扫只读元数据）。
        let sparse = fixture.url.appendingPathComponent("sparse.jsonl.zst")
        fileManager.createFile(atPath: sparse.path, contents: Data())
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 2_553_000_000)
        try handle.close()

        // FIFO 与 Unix 套接字：既不是普通文件也不是目录，类型必须与字典给出的一致。
        let fifo = fixture.url.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o644), 0, "建不了 FIFO，这条对照就没有意义")

        // `sun_path` 只有 104 字节：这条临时目录路径通常放不下，放不下就**不建**套接字
        // ——绝不能截断着 bind，那是在往栈上越界写。其余类别照常对照。
        let socketPath = fixture.url.appendingPathComponent("s").path
        let socketFits = socketPath.utf8.count < 104
        var socketDescriptor: Int32 = -1
        if socketFits {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                socketPath.withCString { source in
                    UnsafeMutableRawPointer(pointer).copyMemory(from: source, byteCount: socketPath.utf8.count + 1)
                }
            }
            socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(socketDescriptor, 0)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            XCTAssertEqual(bound, 0, "建不了 Unix 套接字，这条对照就没有意义")
        }
        defer { if socketDescriptor >= 0 { close(socketDescriptor) } }

        let fileSystem = RealDiscoveryFileSystem()
        var paths: [(String, String)] = [
            ("普通文件", file.path),
            ("空文件", empty.path),
            ("目录", directory.path),
            ("符号链接", link.path),
            ("稀疏大文件", sparse.path),
            ("FIFO", fifo.path),
            ("字符设备", "/dev/null"),
        ]
        if socketFits {
            paths.append(("Unix 套接字", socketPath))
        }

        for (kind, path) in paths {
            let attributes = try XCTUnwrap(fileSystem.attributes(ofItemAt: path), "\(kind) 的属性字典读不出来：\(path)")
            let expectedType = attributes[.type] as? FileAttributeType
            let expectedSize = (attributes[.size] as? NSNumber)?.int64Value

            let metadata = try XCTUnwrap(fileSystem.metadata(ofItemAt: path), "\(kind) 的窄入口读不出来：\(path)")
            XCTAssertEqual(metadata.type, expectedType, "\(kind) 的类型必须与属性字典一致：\(path)")
            XCTAssertEqual(metadata.size, expectedSize, "\(kind) 的大小必须与属性字典一致：\(path)")
        }

        XCTAssertNil(fileSystem.metadata(ofItemAt: fixture.url.appendingPathComponent("不存在").path))
    }

    func test记录器经窄入口仍把这次读取记成一次stat() throws {
        let fixture = try TemporaryDirectoryFixture(named: "metadata-record")
        defer { fixture.remove() }
        let file = fixture.url.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: file)

        let recorder = RecordingDiscoveryFileSystem()
        _ = recorder.metadata(ofItemAt: file.path)

        XCTAssertEqual(
            recorder.accesses,
            [.stat(file.path)],
            "既有替身不改一行也必须在窄入口上留下同一次记录，否则访问范围断言会被绕过"
        )
    }
}
