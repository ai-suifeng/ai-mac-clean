import Foundation

import AIMacCleanDomain
import AIMacCleanRules
import XCTest

/// issue #23：权限错误按目录粒度隔离（PRD §4.4）。
///
/// 一次扫描碰到读不到的目录时，只有那一棵子树读不到——其余照常统计，整次扫描不许失败。
/// 界面拿到的是一份「扫描成功 + 有一处读不到 + 为什么」的结果，而不是一个错误弹窗。
///
/// 用例真的用 `chmod 000` 造一个读不到的目录（不是替身假装失败）：权限错误从
/// `entryNames` 抛出、由扫描器按目录粒度接住，这条路径只有在真实文件系统上才走得通。
final class DeepScanPermissionIsolationTests: XCTestCase {

    private func makeScanner(_ fileSystem: any DiscoveryFileSystem = RealDiscoveryFileSystem()) -> DeepScanner {
        DeepScanner(fileSystem: fileSystem)
    }

    func test读不到的目录被隔离列出而其余统计不受影响() throws {
        let fixture = try DeepScanFixture(named: "permission")
        defer { fixture.remove() }

        let codex = try fixture.tool(
            id: "codex-cli",
            displayName: "Codex CLI",
            relativeRoot: "codex",
            classificationJSON: [
                "{\"pattern\": \"projects/**\", \"category\": \"archivableSession\"}",
            ]
        )
        try fixture.write("codex/projects/-Users-x-a/11111111-1111-1111-1111-111111111111.jsonl", bytes: 1000)
        try fixture.write("codex/projects/-Users-x-b/22222222-2222-2222-2222-222222222222.jsonl", bytes: 2000)

        // 一个读不到的目录：里面有一个 5000 字节的文件，谁也统计不到。
        let secret = try fixture.makeDirectory("codex/projects/-Users-x-secret")
        try Data(repeating: 0x41, count: 5000).write(to: secret.appendingPathComponent("hidden.jsonl"))
        // 另一个读不到的目录：只有它能证明「读不到」不等于「是空的」。
        try fixture.makeDirectory("codex/empty-but-unreadable")
        // 相对工具根的路径（报告里用的形态）。
        let unreadables = ["projects/-Users-x-secret", "empty-but-unreadable"]
        for relative in unreadables {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000],
                ofItemAtPath: fixture.root.appendingPathComponent("codex/" + relative).path
            )
        }
        defer {
            for relative in unreadables {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: fixture.root.appendingPathComponent("codex/" + relative).path
                )
            }
        }

        let scan = makeScanner().scan(
            tools: [fixture.confirmed(codex)],
            rules: [codex.rule],
            homeDirectory: fixture.rootPath
        )

        // 整次扫描照常成功，其余目录照常统计。
        let report = try XCTUnwrap(scan.toolReports.first)
        XCTAssertEqual(
            report.occupancy,
            Occupancy(bytes: 3000, fileCount: 2),
            "读不到的子树只影响它自己：另外两个会话照常统计"
        )
        XCTAssertEqual(report.category(.archivableSession)?.occupancy, Occupancy(bytes: 3000, fileCount: 2))

        // 读不到的位置被如实列出，并带上所属工具与相对路径。
        XCTAssertEqual(
            report.unreadable.map(\.relativePath).sorted(),
            unreadables.sorted(),
            "读不到的目录要单独列出（PRD §4.4：明确列出哪些位置因此无法扫描）"
        )
        XCTAssertTrue(report.unreadable.allSatisfy { $0.kind == .directory })
        XCTAssertTrue(report.unreadable.allSatisfy { $0.toolID == "codex-cli" })
        XCTAssertTrue(
            report.unreadable.allSatisfy { ($0.reason ?? "").isEmpty == false },
            "要给出可读的原因，界面才能引导用户去系统设置：\(report.unreadable.map(\.reason))"
        )
        XCTAssertEqual(scan.unreadable.count, 2, "报告层面也要能一次拿到所有读不到的位置")
    }

    func test读不到的目录不影响别的工具() throws {
        let fixture = try DeepScanFixture(named: "permission-tools")
        defer { fixture.remove() }

        let codex = try fixture.tool(
            id: "codex-cli",
            displayName: "Codex CLI",
            relativeRoot: "codex",
            classificationJSON: ["{\"pattern\": \"projects/**\", \"category\": \"archivableSession\"}"]
        )
        let cursor = try fixture.tool(
            id: "cursor",
            displayName: "Cursor",
            relativeRoot: "cursor",
            classificationJSON: ["{\"pattern\": \"projects/**\", \"category\": \"archivableSession\"}"]
        )
        try fixture.write("codex/projects/-a/11111111-1111-1111-1111-111111111111.jsonl", bytes: 100)
        try fixture.write("cursor/projects/-b/22222222-2222-2222-2222-222222222222.jsonl", bytes: 400)

        let locked = try fixture.makeDirectory("codex/private")
        try Data(repeating: 0x41, count: 999).write(to: locked.appendingPathComponent("x.jsonl"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: locked.path
        )
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        let scan = makeScanner().scan(
            tools: fixture.scanInputs([codex, cursor]),
            rules: [codex.rule, cursor.rule],
            homeDirectory: fixture.rootPath
        )

        XCTAssertEqual(scan.totalOccupancy, Occupancy(bytes: 500, fileCount: 2))
        XCTAssertEqual(scan.toolReport(id: "cursor")?.unreadable, [], "另一台工具不该被牵连")
        XCTAssertEqual(scan.toolReport(id: "codex-cli")?.unreadable.map(\.relativePath), ["private"])
        XCTAssertEqual(scan.unreadable.map(\.toolID), ["codex-cli"])
    }

    func test查不到属性的条目按文件数计入并单独列出() throws {
        let fixture = try DeepScanFixture(named: "vanishing")
        defer { fixture.remove() }

        let codex = try fixture.tool(
            id: "codex-cli",
            displayName: "Codex CLI",
            relativeRoot: "codex",
            classificationJSON: [ "{\"pattern\": \"projects/**\", \"category\": \"archivableSession\"}" ]
        )
        try fixture.write("codex/projects/-a/11111111-1111-1111-1111-111111111111.jsonl", bytes: 64)

        // 「列举得到、查属性查不到」是扫描期间文件被删的形态：不能因此让整次扫描失败，
        // 也不能凭形状猜一个大小——按 0 字节计，并把它列出来。
        let fileSystem = VanishingItemFileSystem(
            wrapped: RealDiscoveryFileSystem(),
            vanishing: fixture.rootPath + "/codex/projects/-a/22222222-2222-2222-2222-222222222222.jsonl"
        )
        try fixture.write("codex/projects/-a/22222222-2222-2222-2222-222222222222.jsonl", bytes: 4096)

        let scan = makeScanner(fileSystem).scan(
            tools: [fixture.confirmed(codex)],
            rules: [codex.rule],
            homeDirectory: fixture.rootPath
        )

        let report = try XCTUnwrap(scan.toolReports.first)
        XCTAssertEqual(
            report.occupancy,
            Occupancy(bytes: 64, fileCount: 1),
            "查不到属性的条目按 0 字节计——宁可少报，也不许凭形状猜一个数"
        )
        // 读不到的那个条目单独列出，界面才能说清「这里少统计了一个文件」。
        XCTAssertEqual(report.unreadable.map(\.relativePath), ["projects/-a/22222222-2222-2222-2222-222222222222.jsonl"])
        XCTAssertEqual(report.unreadable.first?.kind, .item)
    }
}

/// 一个让**指定路径**查不到属性的文件系统替身：模拟扫描期间文件被外部删掉。
///
/// 只改这一个行为，其余照真实文件系统；因此用例断言的是「深扫怎么对待这种条目」，
/// 而不是「替身怎么工作」。
private final class VanishingItemFileSystem: DiscoveryFileSystem, @unchecked Sendable {

    private let wrapped: any DiscoveryFileSystem
    private let vanishing: String

    init(wrapped: any DiscoveryFileSystem, vanishing: String) {
        self.wrapped = wrapped
        self.vanishing = vanishing
    }

    func entryNames(inDirectory path: String) throws -> [String] {
        try wrapped.entryNames(inDirectory: path)
    }

    func attributes(ofItemAt path: String) -> [FileAttributeKey: Any]? {
        guard path != vanishing else { return nil }
        return wrapped.attributes(ofItemAt: path)
    }

    func readHeader(ofFileAt path: String, limit: Int) -> String? {
        wrapped.readHeader(ofFileAt: path, limit: limit)
    }

    func symbolicLinkDestination(atPath path: String) -> String? {
        wrapped.symbolicLinkDestination(atPath: path)
    }
}
