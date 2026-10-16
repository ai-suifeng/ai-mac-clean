import Foundation

import AIMacCleanDomain
import AIMacCleanRules
import XCTest

/// issue #23 验收 7：多工具并行扫描，结果与串行一致（不依赖完成顺序）。
///
/// 本机实测的深扫对象是约 31G / 数万文件，因此不能一台一台串着扫；但并行一旦让结果
/// 依赖「谁先扫完」，用户看到的数字就会随心情变化。这一组用例把两件事同时钉住：
/// 并行**确实发生了**，且**结果与串行逐字节相同**。
final class DeepScanConcurrencyTests: XCTestCase {

    /// 三台形状相同、规模不同的工具。
    private struct Fixture {
        let fixture: DeepScanFixture
        let tools: [DeepScanFixture.Tool]

        func inputs() -> [ConfirmedTool] { tools.map(\.requested) }
        func rules() -> [ToolRule] { tools.map(\.rule) }
    }

    private func makeFixture(named name: String) throws -> Fixture {
        let fixture = try DeepScanFixture(named: name)
        var tools: [DeepScanFixture.Tool] = []
        for (index, id) in ["claude-code", "codex-cli", "cursor"].enumerated() {
            let tool = try fixture.tool(
                id: id,
                displayName: "工具 \(index)",
                relativeRoot: "tool-\(index)",
                classificationJSON: [
                    "{\"pattern\": \"projects/**\", \"category\": \"archivableSession\"}",
                    "{\"pattern\": \".tmp/**\", \"category\": \"cacheAndLog\"}",
                ]
            )
            // 规模刻意不同：完成顺序因此天然不同，结果却必须一样。
            for file in 0...(index * 40) {
                try fixture.write(
                    "tool-\(index)/projects/-a/\(String(format: "%08d", file)).jsonl",
                    bytes: 100 + file
                )
            }
            try fixture.write("tool-\(index)/.tmp/stale.dat", bytes: 7)
            tools.append(tool)
        }
        return Fixture(fixture: fixture, tools: tools)
    }

    func test并行扫描结果与串行完全一致() throws {
        let domain = try makeFixture(named: "concurrency-parity")
        defer { domain.fixture.remove() }

        let serial = DeepScanner(fileSystem: RealDiscoveryFileSystem()).scan(
            tools: domain.inputs(),
            rules: domain.rules(),
            homeDirectory: domain.fixture.rootPath,
            options: .serial
        )
        let parallel = DeepScanner(fileSystem: RealDiscoveryFileSystem()).scan(
            tools: domain.inputs(),
            rules: domain.rules(),
            homeDirectory: domain.fixture.rootPath,
            options: DeepScanOptions(maxConcurrentTools: 4)
        )

        XCTAssertEqual(
            parallel,
            serial,
            "并行扫描结果必须与串行逐字段一致——用户看到的数字不能随完成顺序变化"
        )
        XCTAssertGreaterThan(serial.totalBytes, 0)
        XCTAssertEqual(
            serial.toolReports.map(\.toolID),
            ["claude-code", "codex-cli", "cursor"],
            "顺序固定为工具标识排序，而不是完成顺序"
        )
    }

    func test重复并行扫描结果稳定() throws {
        let domain = try makeFixture(named: "concurrency-stable")
        defer { domain.fixture.remove() }

        let options = DeepScanOptions(maxConcurrentTools: 4)
        let runs = try (0..<5).map { _ in
            DeepScanner(fileSystem: RealDiscoveryFileSystem()).scan(
                tools: domain.inputs(),
                rules: domain.rules(),
                homeDirectory: domain.fixture.rootPath,
                options: options
            )
        }

        for run in runs.dropFirst() {
            XCTAssertEqual(run, runs[0], "同一棵树反复并行扫描必须得到同一份结果")
        }
    }

    func test多台工具确实同时在扫且并发度受选项约束() throws {
        let domain = try makeFixture(named: "concurrency-parallel")
        defer { domain.fixture.remove() }

        // 每次目录列举「卡」一小会儿，把并行窗口拉开——否则扫描太快，峰值可能因为调度
        // 而偶然读到 1，用例就会偶发失败。**断言的是同时有 2 台以上在扫**，不是耗时的
        // 绝对值：那取决于机器与调试信息，断言它只会带来偶发失败。
        let parallel = ConcurrencyProbeFileSystem(
            wrapped: RealDiscoveryFileSystem(),
            root: domain.fixture.rootPath,
            delay: 0.02
        )
        let report = DeepScanner(fileSystem: parallel).scan(
            tools: domain.inputs(),
            rules: domain.rules(),
            homeDirectory: domain.fixture.rootPath,
            options: DeepScanOptions(maxConcurrentTools: 3)
        )

        XCTAssertEqual(report.toolReports.count, 3)
        XCTAssertGreaterThanOrEqual(
            parallel.peakConcurrentTools,
            2,
            "三台工具必须真的并行扫——否则就是「一台 12G 的工具把其余工具排在后面」"
        )

        // 换成串行选项后同一份工作只能一台一台来：峰值必然落到 1。
        let serial = ConcurrencyProbeFileSystem(
            wrapped: RealDiscoveryFileSystem(),
            root: domain.fixture.rootPath,
            delay: 0.02
        )
        let serialReport = DeepScanner(fileSystem: serial).scan(
            tools: domain.inputs(),
            rules: domain.rules(),
            homeDirectory: domain.fixture.rootPath,
            options: .serial
        )

        XCTAssertEqual(serial.peakConcurrentTools, 1, "串行选项下不该有并发")
        XCTAssertEqual(serialReport, report, "并发与否不改变结果")
    }

    func test每台工具自己的目录不会被当成别的工具并行计数() throws {
        let domain = try makeFixture(named: "concurrency-scope")
        defer { domain.fixture.remove() }

        let probe = ConcurrencyProbeFileSystem(
            wrapped: RealDiscoveryFileSystem(),
            root: domain.fixture.rootPath,
            delay: 0.02
        )
        _ = DeepScanner(fileSystem: probe).scan(
            tools: [domain.tools[0].requested],
            rules: [domain.tools[0].rule],
            homeDirectory: domain.fixture.rootPath,
            options: DeepScanOptions(maxConcurrentTools: 4)
        )
        XCTAssertEqual(probe.peakConcurrentTools, 1, "只有一台工具时不可能有并发")
    }

    func test只有一台工具时退化为串行且结果一致() throws {
        let domain = try makeFixture(named: "concurrency-single")
        defer { domain.fixture.remove() }

        let single = [domain.tools[1]]
        let serial = DeepScanner(fileSystem: RealDiscoveryFileSystem()).scan(
            tools: single.map(\.requested),
            rules: single.map(\.rule),
            homeDirectory: domain.fixture.rootPath,
            options: .serial
        )
        let parallel = DeepScanner(fileSystem: RealDiscoveryFileSystem()).scan(
            tools: single.map(\.requested),
            rules: single.map(\.rule),
            homeDirectory: domain.fixture.rootPath,
            options: DeepScanOptions(maxConcurrentTools: 8)
        )
        XCTAssertEqual(parallel, serial)
    }
}

/// 数一数「同时有几台工具在扫」的文件系统替身。
///
/// 它在每次 `entryNames` 时按工具根分组计数，并故意睡一小会儿把窗口拉开——否则
/// 扫描太快，并发峰值可能因为调度而偶然读到 1，用例就会偶发失败。
private final class ConcurrencyProbeFileSystem: DiscoveryFileSystem, @unchecked Sendable {

    private let wrapped: any DiscoveryFileSystem
    private let root: String
    private let delay: TimeInterval
    private let lock = NSLock()

    private var activeTools: Set<String> = []
    private var peak = 0

    init(wrapped: any DiscoveryFileSystem, root: String, delay: TimeInterval) {
        self.wrapped = wrapped
        self.root = root
        self.delay = delay
    }

    /// 同时被扫描的工具数峰值。
    var peakConcurrentTools: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    func entryNames(inDirectory path: String) throws -> [String] {
        let entries = try wrapped.entryNames(inDirectory: path)
        if let tool = toolName(for: path) {
            enter(tool)
            Thread.sleep(forTimeInterval: delay)
            leave(tool)
        }
        return entries
    }

    /// 该路径属于哪台工具（`<root>/tool-N/...`）。
    private func toolName(for path: String) -> String? {
        guard path.hasPrefix(root + "/tool-") else { return nil }
        let relative = String(path.dropFirst(root.count + 1))
        return relative.split(separator: "/").first.map(String.init)
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

    private func enter(_ tool: String) {
        lock.lock()
        defer { lock.unlock() }
        activeTools.insert(tool)
        peak = max(peak, activeTools.count)
    }

    private func leave(_ tool: String) {
        lock.lock()
        defer { lock.unlock() }
        activeTools.remove(tool)
    }
}
