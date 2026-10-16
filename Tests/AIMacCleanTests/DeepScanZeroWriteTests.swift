import Foundation

import AIMacCleanDomain
import XCTest

/// issue #23 验收 3 / 6 的**零写入**证明（review 发现 4 加固）。
///
/// `WriteRecordingDiscoveryFileSystem` 的写尝试记录在接口上不可达
/// （`DiscoveryFileSystem` 没有写入口，深扫拿不到那些方法），因此
/// `writeAttempts == []` 永远不会失败。这一组用例改用一条不依赖被测代码自觉报告的
/// 证明：**扫描前后整棵夹具树逐字段快照一致**（路径 / 类型 / 大小 / 修改时间 / 链接目标）。
final class DeepScanZeroWriteTests: XCTestCase {

    /// 尽量杂的一棵树：普通文件、空目录、受保护目标、指向根外的链接、非 ASCII 名字。
    private func makeFixture() throws -> (fixture: DeepScanFixture, tool: DeepScanFixture.Tool) {
        let fixture = try DeepScanFixture(named: "zero-write-tree")

        try fixture.write(".codex/sessions/2026/10/15/rollout-1.jsonl.zst", bytes: 4096)
        try fixture.write(".codex/auth.json", bytes: 128)
        try fixture.write(".codex/.tmp/陈旧.dat", bytes: 64)
        try fixture.makeDirectory(".codex/空目录")
        // 受保护目标（在工具根之外）与指向它的链接。
        try fixture.write(".agents/skills/技能.md", bytes: 200)
        try fixture.makeSymbolicLink(
            ".codex/skills",
            to: fixture.root.appendingPathComponent(".agents/skills").path
        )
        // 不受保护的外部目标与指向它的链接。
        try fixture.write("movies/巨大的视频.bin", bytes: 100_000)
        try fixture.makeSymbolicLink(
            ".codex/link-out",
            to: fixture.root.appendingPathComponent("movies").path
        )

        let tool = try fixture.tool(
            id: "codex-cli",
            displayName: "Codex CLI",
            relativeRoot: ".codex",
            classificationJSON: [
                "{\"pattern\": \"sessions/**\", \"category\": \"archivableSession\"}",
                "{\"pattern\": \"auth.json\", \"category\": \"protected\"}",
                "{\"pattern\": \".tmp/**\", \"category\": \"cacheAndLog\"}",
            ]
        )
        return (fixture, tool)
    }

    func test深扫前后整棵夹具树逐字段不变() throws {
        let (fixture, tool) = try makeFixture()
        defer { fixture.remove() }

        let auditor = AuditorFileSystem()
        let before = try FileTreeSnapshot.capture(root: fixture.rootPath)

        let report = DeepScanner(fileSystem: auditor).scan(
            tools: [fixture.confirmed(tool)],
            rules: [tool.rule],
            homeDirectory: fixture.rootPath
        )

        let after = try FileTreeSnapshot.capture(root: fixture.rootPath)

        // 这一条能失败，而且失败信息就是两棵树逐条列出的快照。
        XCTAssertEqual(
            after,
            before,
            "深扫整棵树前后必须逐字段一致（路径 / 类型 / 大小 / 修改时间 / 链接目标）。"
                + "\n扫描前：\n\(before)\n扫描后：\n\(after)"
        )
        // 顺带保留接缝级断言：它读起来仍然清楚（只是不再单独承担「零写入」的证明）。
        XCTAssertEqual(auditor.writeAttempts, [], "深扫全程零写入：\n\(auditor.writeSummary)")
        XCTAssertGreaterThan(report.totalBytes, 0, "对照组：这次扫描真的读到了东西")
    }

    /// 快照不是空话：真的改动树，快照必须不同——否则上面的「前后一致」可能只是因为它
    /// 什么都没看。三条各自证明一类改动（写字节 / 新增 / 删除）。
    func test快照能发现树上的任何变化() throws {
        let fixture = try DeepScanFixture(named: "zero-write-snapshot")
        defer { fixture.remove() }

        try fixture.write(".codex/sessions/rollout-1.jsonl", bytes: 64)
        let baseline = try FileTreeSnapshot.capture(root: fixture.rootPath)

        // 1. 改一个字节（大小与 mtime 都会变）。
        try fixture.write(".codex/sessions/rollout-1.jsonl", bytes: 128)
        let rewritten = try FileTreeSnapshot.capture(root: fixture.rootPath)
        XCTAssertNotEqual(rewritten, baseline, "写字节必须能被快照看见")

        // 2. 新增一个条目。
        try fixture.write(".codex/sessions/rollout-2.jsonl", bytes: 8)
        let added = try FileTreeSnapshot.capture(root: fixture.rootPath)
        XCTAssertNotEqual(added, rewritten, "新增条目必须能被快照看见")

        // 3. 删掉一个条目。
        try FileManager.default.removeItem(
            at: fixture.root.appendingPathComponent(".codex/sessions/rollout-2.jsonl")
        )
        let removed = try FileTreeSnapshot.capture(root: fixture.rootPath)
        XCTAssertNotEqual(removed, added, "删除条目必须能被快照看见")

        // 4. 改链接目标（先删旧链接再建，目标用夹具里真实存在的目录，避免悬空链接干扰删除）。
        let firstTarget = try fixture.makeDirectory("targets/first")
        let secondTarget = try fixture.makeDirectory("targets/second")
        try fixture.makeSymbolicLink(".codex/link", to: firstTarget.path)
        let linked = try FileTreeSnapshot.capture(root: fixture.rootPath)
        try? FileManager.default.removeItem(at: fixture.root.appendingPathComponent(".codex/link"))
        try fixture.makeSymbolicLink(".codex/link", to: secondTarget.path)
        let relinked = try FileTreeSnapshot.capture(root: fixture.rootPath)
        XCTAssertNotEqual(relinked, linked, "改链接目标必须能被快照看见")
        XCTAssertTrue(
            relinked.description.contains(secondTarget.path),
            "快照要如实记下链接目标：\n\(relinked.description)"
        )
    }
}
