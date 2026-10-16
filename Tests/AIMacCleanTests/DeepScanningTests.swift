import Foundation

import AIMacCleanDomain
import AIMacCleanRules
import XCTest

/// issue #23：深扫器核心——递归算占用 + 按四类分类。
///
/// 这一组用例只断言**外部可观察行为**：每个工具 / 每个类别 / 每个子路径的字节数与
/// 文件数、哪些位置读不到、哪些链接没有跟随；并把「零写入」与「不跟随符号链接」
/// 变成可断言的事实。
final class DeepScanningTests: XCTestCase {

    // MARK: - 夹具

    private let archivable = "{\"pattern\": \"projects/**\", \"category\": \"archivableSession\"}"
    private let cacheAndLog = "{\"pattern\": \".tmp/**\", \"category\": \"cacheAndLog\"}"
    private let uncertain = "{\"pattern\": \"weird/**\", \"category\": \"uncertain\"}"

    private func tool(_ fixture: DeepScanFixture, relativeRoot: String = ".codex") throws -> DeepScanFixture.Tool {
        try fixture.tool(
            id: "codex-cli",
            displayName: "Codex CLI",
            relativeRoot: relativeRoot,
            classificationJSON: [archivable, cacheAndLog, uncertain]
        )
    }

    private func makeScanner(_ fileSystem: any DiscoveryFileSystem) -> DeepScanner {
        DeepScanner(fileSystem: fileSystem)
    }

    /// 按「类别 + 子路径」取一条汇总；取不到就断言失败（附上实际拿到的汇总）。
    private func summary(
        _ report: ToolScanReport,
        _ category: DataCategory,
        _ subpath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CategorySummary? {
        let found = report.category(category)?.summaries.first { $0.subpath == subpath }
        if found == nil {
            XCTFail(
                "没找到「\(category.rawValue) / \(subpath)」这条汇总。"
                    + "实际：\(report.categories.map { "\($0.category.rawValue)[\($0.summaries.map(\.subpath))]" })",
                file: file,
                line: line
            )
        }
        return found
    }

    // MARK: - 验收 1：递归算占用

    func test每个工具的字节数与文件数含嵌套空目录与零字节文件() throws {
        let fixture = try DeepScanFixture(named: "totals")
        defer { fixture.remove() }

        let codex = try tool(fixture)
        try fixture.write(".codex/projects/-Users-x-a/11111111-1111-1111-1111-111111111111.jsonl", bytes: 1024)
        try fixture.write(".codex/projects/-Users-x-a/22222222-2222-2222-2222-222222222222.jsonl", bytes: 2048)
        try fixture.write(".codex/projects/-Users-x-a/empty.jsonl", bytes: 0)
        try fixture.write(".codex/sessions/2026/10/14/rollout-2026-10-14T10-00-00.jsonl.zst", bytes: 4096)
        try fixture.write(".codex/sessions/2026/10/14/deep/nested/note.bin", bytes: 512)
        try fixture.makeDirectory(".codex/empty-directory")
        try fixture.write(".codex/.tmp/stale.dat", bytes: 256)
        try fixture.write(".codex/config.toml", bytes: 64)

        let scan = makeScanner(RecordingDiscoveryFileSystem()).scan(
            tools: [fixture.confirmed(codex)],
            rules: [codex.rule],
            homeDirectory: fixture.rootPath
        )

        let report = try XCTUnwrap(scan.toolReports.first)
        XCTAssertEqual(report.toolID, "codex-cli")
        XCTAssertEqual(report.displayName, "Codex CLI")
        XCTAssertEqual(report.occupancy, Occupancy(bytes: 1024 + 2048 + 0 + 4096 + 512 + 256 + 64, fileCount: 7))
        XCTAssertEqual(scan.totalOccupancy, report.occupancy, "总量是各工具之和")
    }

    func test合计字节数与逐文件相加一致且不读文件内容() throws {
        let fixture = try DeepScanFixture(named: "no-content-read")
        defer { fixture.remove() }

        let codex = try tool(fixture)
        try fixture.write(".codex/projects/p/a.jsonl", bytes: 100)
        try fixture.write(".codex/projects/p/b.jsonl", bytes: 200)

        let recorder = RecordingDiscoveryFileSystem()
        let scan = makeScanner(recorder).scan(
            tools: [fixture.confirmed(codex)],
            rules: [codex.rule],
            homeDirectory: fixture.rootPath
        )

        XCTAssertEqual(scan.totalOccupancy, Occupancy(bytes: 300, fileCount: 2))
        XCTAssertEqual(
            recorder.accesses.filter { if case .header = $0 { return true } else { return false } },
            [],
            "深扫只读元数据：一个文件头都不该读（PRD §13 第 3 条）。实际：\n\(recorder.summary)"
        )
    }

    // MARK: - 验收 6：深扫全程零写入

    func test深扫全程零写入即使树里有空目录与读不到的目录() throws {
        let fixture = try DeepScanFixture(named: "zero-write")
        defer { fixture.remove() }

        let codex = try tool(fixture)
        try fixture.write(".codex/projects/-Users-x-a/11111111-1111-1111-1111-111111111111.jsonl", bytes: 128)
        try fixture.makeDirectory(".codex/empty")
        // 读不到的目录同样不许触发任何「顺手修一下权限」之类的写操作。
        let locked = try fixture.makeDirectory(".codex/locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        let auditor = AuditorFileSystem()
        let scan = makeScanner(auditor).scan(
            tools: [fixture.confirmed(codex)],
            rules: [codex.rule],
            homeDirectory: fixture.rootPath
        )

        XCTAssertEqual(scan.totalOccupancy, Occupancy(bytes: 128, fileCount: 1))
        XCTAssertEqual(auditor.writeAttempts, [], "深扫只读：没有创建、没有覆写、没有移动、没有删除")
        XCTAssertEqual(auditor.writeSummary, "零写入（没有任何写尝试）")
    }

    // MARK: - 验收 2：四类各自的字节数与文件数

    func test四类各自的字节数与文件数正确且目录只算一次() throws {
        let fixture = try DeepScanFixture(named: "categories")
        defer { fixture.remove() }

        let codex = try tool(fixture)
        try fixture.write(".codex/projects/-Users-x-a/11111111-1111-1111-1111-111111111111.jsonl", bytes: 1000)
        try fixture.write(".codex/projects/-Users-x-a/agent-22222222-2222-2222-2222-222222222222.jsonl", bytes: 500)
        try fixture.write(".codex/.tmp/stale-1.dat", bytes: 300)
        try fixture.write(".codex/.tmp/stale-2.dat", bytes: 40)
        try fixture.write(".codex/weird/mystery.bin", bytes: 77)

        let scan = makeScanner(RecordingDiscoveryFileSystem()).scan(
            tools: [fixture.confirmed(codex)],
            rules: [codex.rule],
            homeDirectory: fixture.rootPath
        )

        let report = try XCTUnwrap(scan.toolReports.first)
        XCTAssertEqual(report.category(.archivableSession)?.occupancy, Occupancy(bytes: 1500, fileCount: 2))
        XCTAssertEqual(report.category(.cacheAndLog)?.occupancy, Occupancy(bytes: 340, fileCount: 2))
        XCTAssertEqual(report.category(.uncertain)?.occupancy, Occupancy(bytes: 77, fileCount: 1))
        XCTAssertNil(
            report.category(.protected),
            "这一类下什么都没有时不留占位空行——界面不该显示一行 0 B / 0 个文件"
        )

        XCTAssertEqual(
            report.category(.archivableSession)?.summaries.map(\.subpath),
            ["projects"],
            "可归档只声明了 projects/**，子路径汇总就只该有 projects 一条"
        )
        XCTAssertEqual(summary(report, .archivableSession, "projects")?.occupancy,
                       Occupancy(bytes: 1500, fileCount: 2))
        XCTAssertEqual(summary(report, .cacheAndLog, ".tmp")?.occupancy,
                       Occupancy(bytes: 340, fileCount: 2))
        XCTAssertEqual(summary(report, .uncertain, "weird")?.occupancy,
                       Occupancy(bytes: 77, fileCount: 1))

        XCTAssertEqual(
            report.holdingDirectoryCount,
            3,
            "装着文件的锚点目录：.tmp、projects、weird 各一个——不是文件数，也不是子路径条数"
        )
    }

    func test按子路径汇总到命中规则的目录层级() throws {
        let fixture = try DeepScanFixture(named: "subpaths")
        defer { fixture.remove() }

        let codex = try tool(fixture)
        try fixture.write(".codex/projects/-Users-x-a/11111111-1111-1111-1111-111111111111.jsonl", bytes: 128)
        try fixture.write(".codex/projects/-Users-x-b/22222222-2222-2222-2222-222222222222.jsonl", bytes: 256)
        try fixture.write(".codex/.tmp/nested/deeper/stale.dat", bytes: 32)

        let scan = makeScanner(RecordingDiscoveryFileSystem()).scan(
            tools: [fixture.confirmed(codex)],
            rules: [codex.rule],
            homeDirectory: fixture.rootPath
        )

        let report = try XCTUnwrap(scan.toolReports.first)
        XCTAssertEqual(report.category(.archivableSession)?.summaries.map(\.subpath), ["projects"])
        XCTAssertEqual(report.category(.archivableSession)?.summaries.first?.occupancy,
                       Occupancy(bytes: 384, fileCount: 2))
        XCTAssertEqual(report.category(.cacheAndLog)?.summaries.map(\.subpath), [".tmp"])
        XCTAssertEqual(report.category(.cacheAndLog)?.summaries.first?.occupancy,
                       Occupancy(bytes: 32, fileCount: 1))
    }

    // MARK: - 验收 2 的关键断言：规则未声明 → 不确定

    func test规则未声明的路径落进不确定而不是可归档() throws {
        let fixture = try DeepScanFixture(named: "undeclared")
        defer { fixture.remove() }

        let codex = try tool(fixture)
        try fixture.write(".codex/projects/-Users-x-a/11111111-1111-1111-1111-111111111111.jsonl", bytes: 4096)
        // 一条形状完全像会话、但规则没声明的路径：这是最危险的误判来源。
        try fixture.write(".codex/sessions/2026/10/14/rollout-2026-10-14T10-00-00.jsonl", bytes: 8192)
        try fixture.write(".codex/unknown-place/notes.txt", bytes: 10)
        try fixture.write(".codex/another.jsonl", bytes: 20)

        let scan = makeScanner(RecordingDiscoveryFileSystem()).scan(
            tools: [fixture.confirmed(codex)],
            rules: [codex.rule],
            homeDirectory: fixture.rootPath
        )

        let report = try XCTUnwrap(scan.toolReports.first)
        XCTAssertEqual(
            report.category(.archivableSession)?.occupancy,
            Occupancy(bytes: 4096, fileCount: 1),
            "只有 projects/** 声明为可归档；未声明的 8192 字节绝不许算进来"
        )
        XCTAssertEqual(
            report.category(.uncertain)?.occupancy,
            Occupancy(bytes: 8192 + 10 + 20, fileCount: 3),
            "未声明的路径一律落进不确定（GLOSSARY「不确定」：无法安全分类）"
        )
        XCTAssertEqual(
            report.category(.uncertain)?.summaries.map(\.subpath),
            ["sessions", "another.jsonl", "unknown-place"],
            "未声明的路径按工具根下的顶层子项各自成一条（字节多的在前），"
                + "便于界面说明「这些地方没被规则声明」"
        )
        XCTAssertEqual(
            report.category(.uncertain)?.summaries.compactMap(\.pattern),
            [],
            "未声明的路径没有可展示的规则模式——它们是「规则一个都没声明到」"
        )
        XCTAssertEqual(
            report.category(.uncertain)?.summaries.map(\.provenance),
            [.undeclared, .undeclared, .undeclared]
        )
    }

    /// 一条声明可以落在**文件**上（`config.toml`），也可以落在**目录树**上（`.tmp/**`）。
    ///
    /// 注意 `.tmp`（不带 `/**`）只覆盖那个目录本身，**不覆盖**里面的文件——
    /// 匹配语义是整条相对路径（PRD §5.2、`docs/rule-format.md`），因此想管住
    /// 目录里的东西必须写 `.tmp/**`。写成裸目录名不会报错，但内容会落到不确定档：
    /// 这是保守方向（宁可少报可归档，也不多报），下一条用例专门钉住它。
    func test声明了类别的文件按声明分类() throws {
        let fixture = try DeepScanFixture(named: "declared-file")
        defer { fixture.remove() }

        let codex = try fixture.tool(
            id: "codex-cli",
            displayName: "Codex CLI",
            relativeRoot: ".codex",
            classificationJSON: [
                "{\"pattern\": \"projects/**\", \"category\": \"archivableSession\"}",
                "{\"pattern\": \"config.toml\", \"category\": \"protected\"}",
                "{\"pattern\": \".tmp/**\", \"category\": \"cacheAndLog\"}",
            ]
        )
        try fixture.write(".codex/config.toml", bytes: 40)
        try fixture.write(".codex/projects/p/a.jsonl", bytes: 60)
        try fixture.write(".codex/.tmp/x.dat", bytes: 8)

        let scan = makeScanner(RecordingDiscoveryFileSystem()).scan(
            tools: [fixture.confirmed(codex)],
            rules: [codex.rule],
            homeDirectory: fixture.rootPath
        )

        let report = try XCTUnwrap(scan.toolReports.first)
        XCTAssertEqual(report.category(.protected)?.occupancy, Occupancy(bytes: 40, fileCount: 1))
        XCTAssertEqual(report.category(.protected)?.summaries.map(\.subpath), ["config.toml"])
        XCTAssertEqual(report.category(.archivableSession)?.occupancy, Occupancy(bytes: 60, fileCount: 1))
        XCTAssertEqual(
            report.category(.cacheAndLog)?.occupancy,
            Occupancy(bytes: 8, fileCount: 1),
            "`.tmp/**` 管住目录里的内容"
        )
        XCTAssertEqual(report.category(.cacheAndLog)?.summaries.map(\.subpath), [".tmp"])
    }

    /// 裸目录名只覆盖目录本身，不覆盖里面的文件——内容落进不确定，绝不落进可归档。
    func test裸目录名不覆盖目录里的文件() throws {
        let fixture = try DeepScanFixture(named: "bare-directory-pattern")
        defer { fixture.remove() }

        let codex = try fixture.tool(
            id: "codex-cli",
            displayName: "Codex CLI",
            relativeRoot: ".codex",
            classificationJSON: [
                "{\"pattern\": \"cache\", \"category\": \"cacheAndLog\"}",
            ]
        )
        try fixture.write(".codex/cache/x.dat", bytes: 8)

        let scan = makeScanner(RecordingDiscoveryFileSystem()).scan(
            tools: [fixture.confirmed(codex)],
            rules: [codex.rule],
            homeDirectory: fixture.rootPath
        )

        let report = try XCTUnwrap(scan.toolReports.first)
        XCTAssertNil(report.category(.cacheAndLog), "裸目录名不匹配目录里的文件（PRD §5.2 的整条相对路径语义）")
        XCTAssertEqual(
            report.category(.uncertain)?.occupancy,
            Occupancy(bytes: 8, fileCount: 1),
            "没被声明覆盖 → 不确定；写成裸目录名只是没生效，不会把数据变成可归档"
        )
    }

    /// 一条路径同时命中多条声明时，报**判定顺序**最高的那一类（issue #25 验收 6）：
    /// 受保护 > 不确定 > 缓存与日志 > 可归档会话。取向只有一个——越不容易丢数据越靠前。
    func test同一路径命中多条声明时按判定顺序归属() throws {
        let fixture = try DeepScanFixture(named: "precedence")
        defer { fixture.remove() }

        // 宽泛的可归档声明写在**前**、受保护声明写在**后**：按声明顺序会取到可归档，
        // 按判定顺序必须取到受保护。
        let codex = try fixture.tool(
            id: "codex-cli",
            displayName: "Codex CLI",
            relativeRoot: ".codex",
            classificationJSON: [
                "{\"pattern\": \"data/**\", \"category\": \"archivableSession\"}",
                "{\"pattern\": \"data/*.sqlite\", \"category\": \"protected\"}",
                "{\"pattern\": \"data/*.bin\", \"category\": \"cacheAndLog\"}",
                "{\"pattern\": \"data/*.blob\", \"category\": \"uncertain\"}",
            ]
        )
        try fixture.write(".codex/data/state.sqlite", bytes: 400)
        try fixture.write(".codex/data/run.bin", bytes: 30)
        try fixture.write(".codex/data/thing.blob", bytes: 5)
        try fixture.write(".codex/data/session.jsonl", bytes: 500)

        let scan = makeScanner(RecordingDiscoveryFileSystem()).scan(
            tools: [fixture.confirmed(codex)],
            rules: [codex.rule],
            homeDirectory: fixture.rootPath
        )

        let report = try XCTUnwrap(scan.toolReports.first)
        XCTAssertEqual(
            report.category(.archivableSession)?.occupancy,
            Occupancy(bytes: 500, fileCount: 1),
            "只有真正只命中可归档那一条的会话才算可归档"
        )
        XCTAssertEqual(
            report.category(.protected)?.occupancy,
            Occupancy(bytes: 400, fileCount: 1),
            "受保护是最高档：写在后面的受保护声明不能被写在前面的大范围可归档声明盖过"
        )
        XCTAssertEqual(
            report.category(.cacheAndLog)?.occupancy,
            Occupancy(bytes: 30, fileCount: 1),
            "缓存与日志高于可归档会话"
        )
        XCTAssertEqual(
            report.category(.uncertain)?.occupancy,
            Occupancy(bytes: 5, fileCount: 1),
            "不确定高于可归档会话（同一路径上的不确定声明压过宽泛的可归档声明）"
        )
    }

    func test未在任何规则里的工具零占用且不留空类别() throws {
        let fixture = try DeepScanFixture(named: "unknown-tool")
        defer { fixture.remove() }

        let codex = try tool(fixture)
        let ghost = ConfirmedTool(id: "ghost", displayName: "Ghost", toolRootPath: fixture.rootPath + "/.ghost")

        let scan = makeScanner(RecordingDiscoveryFileSystem()).scan(
            tools: [fixture.confirmed(codex), ghost],
            rules: [codex.rule],
            homeDirectory: fixture.rootPath
        )

        let report = try XCTUnwrap(scan.toolReports.first { $0.toolID == "ghost" })
        XCTAssertEqual(report.occupancy, Occupancy(bytes: 0, fileCount: 0))
        XCTAssertEqual(report.categories, [], "没有任何东西落在任何一类下时，不留占位的空类别")
        XCTAssertEqual(report.holdingDirectoryCount, 0)
        XCTAssertEqual(scan.totalOccupancy, Occupancy(bytes: 0, fileCount: 0))
    }
}
