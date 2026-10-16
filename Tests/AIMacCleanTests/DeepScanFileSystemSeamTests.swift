import Foundation

import AIMacCleanDomain
import XCTest

/// issue #23 切片 1：深扫要能**证明**自己只读、且不跟随符号链接，
/// 于是注入的文件系统缝得先能看见这两件事。
///
/// 这一组用例断言的是接缝本身的行为（记录器记录得准不准），
/// 深扫的对外行为由后续几组用例断言。
final class DeepScanFileSystemSeamTests: XCTestCase {

    func test真实文件系统能读出符号链接自己的类型与目标() throws {
        let fixture = try TemporaryDirectoryFixture(named: "seam-symlink")
        defer { fixture.remove() }

        let target = try fixture.makeDirectory("real")
        try Data("hello".utf8).write(to: target.appendingPathComponent("a.txt"))
        let link = fixture.url.appendingPathComponent("link-dir")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

        let fileSystem = RealDiscoveryFileSystem()

        let attributes = try XCTUnwrap(fileSystem.attributes(ofItemAt: link.path))
        XCTAssertEqual(
            attributes[.type] as? FileAttributeType,
            .typeSymbolicLink,
            "属性必须读条目**自身**：返回链接目标的目录类型就等于跟随了符号链接"
        )
        XCTAssertEqual(
            fileSystem.symbolicLinkDestination(atPath: link.path),
            target.path,
            "链接目标要能原样读出来，才能判「指向工具根之外」"
        )

        let plain = try XCTUnwrap(fileSystem.attributes(ofItemAt: target.appendingPathComponent("a.txt").path))
        XCTAssertEqual(plain[.type] as? FileAttributeType, .typeRegular)
        XCTAssertNil(
            fileSystem.symbolicLinkDestination(atPath: target.appendingPathComponent("a.txt").path),
            "不是符号链接时不该给出目标"
        )
    }

    func test记录器把符号链接目标作为一次读取记下() throws {
        let fixture = try TemporaryDirectoryFixture(named: "seam-record")
        defer { fixture.remove() }

        let target = try fixture.makeDirectory("real")
        let link = fixture.url.appendingPathComponent("link-dir")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

        let recorder = RecordingDiscoveryFileSystem()
        _ = recorder.symbolicLinkDestination(atPath: link.path)

        XCTAssertEqual(recorder.accesses, [.link(link.path)], "读链接目标必须留下记录——它是「碰了哪里」的一部分")
        XCTAssertTrue(recorder.summary.contains("读取链接目标"), "摘要要能一眼看出碰过链接：\(recorder.summary)")
    }

    func test记录器初始没有任何写尝试而写操作会留下痕迹() throws {
        let fixture = try TemporaryDirectoryFixture(named: "seam-write")
        defer { fixture.remove() }

        let recorder = RecordingDiscoveryFileSystem()
        XCTAssertEqual(recorder.writeAttempts, [], "还没做事时不该有任何写尝试")
        XCTAssertEqual(recorder.writeSummary, "零写入（没有任何写尝试）")

        // 记录器**不是**只读替身：写操作照样落到磁盘上（否则「没写」可能只是「写失败了」）。
        let created = fixture.url.appendingPathComponent("created")
        try recorder.createDirectory(atPath: created.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path), "写操作要真的执行，记录才有意义")
        XCTAssertEqual(recorder.writeAttempts, [.createDirectory(created.path)])

        let file = created.appendingPathComponent("note.txt")
        try recorder.writeFile(atPath: file.path, contents: Data("hi".utf8))
        try recorder.moveItem(atPath: file.path, toPath: created.appendingPathComponent("moved.txt").path)
        try recorder.removeItem(atPath: created.appendingPathComponent("moved.txt").path)

        XCTAssertEqual(recorder.writeAttempts.count, 4, "四类写操作各自留下一条记录：\(recorder.writeSummary)")

        recorder.resetWrites()
        XCTAssertEqual(recorder.writeAttempts, [])
    }

    func test审计记录器不放行任何写操作到深扫眼里() throws {
        let fixture = try TemporaryDirectoryFixture(named: "seam-audit")
        defer { fixture.remove() }
        _ = try fixture.makeDirectory("child")

        let auditor = AuditorFileSystem()
        // 只读的几件事不该产生写尝试。
        _ = try auditor.entryNames(inDirectory: fixture.url.path)
        _ = auditor.attributes(ofItemAt: fixture.url.path)
        _ = auditor.symbolicLinkDestination(atPath: fixture.url.path)

        XCTAssertEqual(auditor.writeAttempts, [], "只读操作不能被记成写尝试：\(auditor.writeSummary)")
    }
}
