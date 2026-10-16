import Foundation

import AIMacCleanDomain
import AIMacCleanRules
import AIMacCleanUI
import XCTest

/// issue #29：深扫的**规模与性能验收**。
///
/// 这一组用例回答的不是「小夹具上跑得动吗」，而是「在真实量级的数据上还能不能用」。
/// 规模取自 PRD §14 的实测：`~/.codex/.tmp` 一处 **24,849 个文件**、单个 Codex 会话
/// **2.38 GiB**、单行最长 **19.4 MB**、总量约 **31 G**；本票把文件数量级抬到 **≥ 5 万**，
/// 并要求四条断言各有对应用例：
///
/// 1. 时限（`test五万文件合成树在标定时限内扫完并算对四类占用`）；
/// 2. 不阻塞调用线程（`test扫描经DiscoveryScheduler在后台执行且调用线程全程可继续工作`）；
/// 3. 保留量不随文件数线性膨胀（`test汇总条目不随文件数线性膨胀`）；
/// 4. 访问范围只在已确认工具的工具根内（`test规模树下访问范围只落在已确认工具的工具根内`）；
///    外加规模下的符号链接与权限错误（`test规模树下符号链接与权限错误仍按目录粒度隔离`）
///    与大文件（`test单个会话大到5GiB时仍只读元数据且耗时与文件大小无关`）。
///
/// ## 时限是怎么标定的（不接受没有出处的魔法数字）
///
/// 本机实测（Apple Silicon / macOS 14 / `swift test` 调试构建 / 2026-10-15，issue #29 评论）：
///
/// - **优化前**：50,003 个文件的合成树 **132.4s**。逐文件受保护判定约 2.1ms/次，
///   其中大头是每次判定都重新解析工具根 / 主目录的符号链接、重新展开受保护目录，
///   以及为每个文件构造整本属性字典（64µs vs 一次 `lstat` 3.8µs）。
/// - **优化后**：同一棵树 **5.4s**（一次扫描一份受保护判定快照、逐文件一次 `lstat`、
///   预编译的分类模式）。
///
/// 现值取 **20s ≈ 实测的 3.7 倍**：CI 机器更慢、并行度更高，留足噪声余量；同时它比
/// 优化前的 132.4s 快 **6.6 倍**——也就是说**旧行为必然红**，这道闸门仍然拦得住退化。
/// 需要临时放宽（例如在很慢的机器上）时设 `AMC_SCAN_SCALE_BUDGET_SECONDS`。
final class DeepScanScaleTests: XCTestCase {

    /// 实测 5.4s 的 3.7 倍；出处见类型注释。
    private static let defaultBudgetSeconds: TimeInterval = 20

    private var budgetSeconds: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["AMC_SCAN_SCALE_BUDGET_SECONDS"],
           let value = TimeInterval(raw), value > 0 {
            return value
        }
        return Self.defaultBudgetSeconds
    }

    // MARK: - 夹具助手

    /// 一台已确认工具 + 它的规则 + 一次扫描。
    private struct Domain {
        let fixture: ScaleTreeFixture
        let shape: ScaleTreeFixture.Shape
        let manifest: ScaleTreeFixture.Manifest
        let tool: ConfirmedTool
        let rule: ToolRule

        func scan(_ fileSystem: any DiscoveryFileSystem = RealDiscoveryFileSystem()) -> DeepScanReport {
            DeepScanner(fileSystem: fileSystem).scan(
                tools: [tool],
                rules: [rule],
                homeDirectory: fixture.rootPath
            )
        }
    }

    private func makeDomain(
        named name: String,
        shape: ScaleTreeFixture.Shape = ScaleTreeFixture.Shape()
    ) throws -> Domain {
        let fixture = try ScaleTreeFixture(named: name)
        let manifest = try fixture.build(shape)
        let (tool, rule) = try fixture.tool(for: shape)
        return Domain(fixture: fixture, shape: shape, manifest: manifest, tool: tool, rule: rule)
    }

    private func summaries(_ report: ToolScanReport) -> [CategorySummary] {
        report.categories.flatMap(\.summaries)
    }

    // MARK: - 验收 1：时限（文件数量级）

    func test五万文件合成树在标定时限内扫完并算对四类占用() throws {
        let domain = try makeDomain(named: "fifty-thousand")
        defer { domain.fixture.remove() }

        XCTAssertGreaterThanOrEqual(
            domain.manifest.shape.totalFileCount,
            50_000,
            "这条用例的前提就是「≥ 5 万文件」；夹具不达标时它没有意义"
        )

        let started = Date()
        let report = try XCTUnwrap(domain.scan().toolReports.first)
        let elapsed = Date().timeIntervalSince(started)
        // 打出来是为了让标定出处留在 CI 日志里：时限改了、机器换了，都能一眼看出差多少。
        print("▸ 深扫规模：\(domain.manifest.shape.totalFileCount) 文件 / "
            + "\(domain.manifest.shape.totalBytes) 字节，耗时 \(String(format: "%.3f", elapsed))s"
            + "（时限 \(budgetSeconds)s）")

        XCTAssertLessThanOrEqual(
            elapsed,
            budgetSeconds,
            "5 万文件必须在标定时限内扫完（实测 5.4s，时限 \(budgetSeconds)s；"
                + "出处见 DeepScanScaleTests 的类型注释）。实际 \(String(format: "%.3f", elapsed))s"
        )

        // 算得对：与夹具清单逐项对照（清单由构建参数算出，不是再扫一遍得到的）。
        XCTAssertEqual(
            report.occupancy,
            Occupancy(bytes: domain.manifest.shape.totalBytes, fileCount: domain.manifest.shape.totalFileCount),
            "总占用必须精确到字节：稀疏大文件 2.38 GiB / 19.4 MB 这类量级最容易在取整或截断里露馅"
        )
        XCTAssertEqual(
            report.category(.archivableSession)?.occupancy,
            Occupancy(bytes: domain.manifest.sessionBytes, fileCount: domain.manifest.sessionFileCount)
        )
        XCTAssertEqual(
            report.category(.cacheAndLog)?.occupancy,
            Occupancy(bytes: domain.manifest.cacheBytes, fileCount: domain.manifest.cacheFileCount)
        )
        XCTAssertNil(
            report.category(.uncertain),
            "规则没声明到的路径才落不确定；这棵树里每个文件都被声明覆盖"
        )
        XCTAssertEqual(report.unreadable, [], "干净的树不该有读不到的位置")
        XCTAssertEqual(report.unfollowedLinks, [], "干净的树里没有符号链接")

        // 保留量与文件数无关：5 万个文件也只汇总到「声明的那几层」。
        XCTAssertEqual(
            summaries(report).map(\.subpath).sorted(),
            [".tmp", "sessions"],
            "5 万文件只该汇总成两个锚点——这份报告里不可能驻留一份 5 万条的清单"
        )
    }

    // MARK: - 验收 1 的另一半：大文件（只读元数据，耗时与文件大小无关）

    func test单个会话大到5GiB时仍只读元数据且耗时与文件大小无关() throws {
        let fixture = try ScaleTreeFixture(named: "large-file")
        defer { fixture.remove() }

        var shape = ScaleTreeFixture.Shape()
        shape.shardCount = 2
        shape.bucketsPerShard = 1
        shape.smallFilesPerBucket = 100
        // 5 GiB：跨过 Int32 上限（2.38 GiB 的会话与 19.4 MB 的单行，量级照抄 PRD §14）。
        shape.largeFiles = [
            (relativePath: "sessions/2026/10/15/rollout-huge.jsonl.zst", bytes: 5_368_709_120),
            (relativePath: "sessions/2026/10/15/rollout-huge-line.jsonl", bytes: 19_400_000),
        ]
        let manifest = try fixture.build(shape)
        let (tool, rule) = try fixture.tool(for: shape)

        let recorder = RecordingDiscoveryFileSystem()
        let started = Date()
        let report = try XCTUnwrap(
            DeepScanner(fileSystem: recorder)
                .scan(tools: [tool], rules: [rule], homeDirectory: fixture.rootPath)
                .toolReports.first
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertGreaterThan(
            manifest.shape.totalBytes,
            Int64(Int32.max),
            "夹具必须跨过 Int32 上限，逐级取整或截断才会露馅"
        )
        XCTAssertEqual(
            report.occupancy,
            Occupancy(bytes: manifest.shape.totalBytes, fileCount: manifest.shape.totalFileCount)
        )
        XCTAssertEqual(
            recorder.accesses.filter { if case .header = $0 { return true } else { return false } },
            [],
            "深扫只读元数据：一个文件头都不许读（PRD §13 第 3 条、M2 spec「只读元数据与少量文件头」）"
        )
        XCTAssertLessThanOrEqual(
            elapsed,
            1.0,
            "202 个文件、其中一个是 5 GiB：只读元数据的扫描不该因为文件大而变慢"
                + "（本机实测 < 0.1s，1s 是十倍余量）。实际 \(String(format: "%.3f", elapsed))s"
        )
    }

    // MARK: - 验收 2：不阻塞调用线程（沿用 issue #21 的 DiscoveryScheduler）

    func test扫描经DiscoveryScheduler在后台执行且调用线程全程可继续工作() throws {
        let fixture = try ScaleTreeFixture(named: "scheduler")
        defer { fixture.remove() }

        var shape = ScaleTreeFixture.Shape()
        shape.shardCount = 20
        shape.bucketsPerShard = 1
        shape.smallFilesPerBucket = 20
        let manifest = try fixture.build(shape)
        let (tool, rule) = try fixture.tool(for: shape)

        // 每次目录列举睡 5ms：把扫描窗口拉长到几十毫秒，「调用线程有没有被挡住」才有可观察的差别。
        // 断言的是**线程归属**，不是耗时——耗时随机器与调试信息变化，断言它只会带来偶发失败。
        let scanner = DeepScanner(
            fileSystem: SlowDirectoryListingFileSystem(wrapped: RealDiscoveryFileSystem(), delay: 0.005)
        )
        let scheduler = DiscoveryScheduler.background()

        let scanStarted = DispatchSemaphore(value: 0)
        let callingThreadWorked = DispatchSemaphore(value: 0)
        var scannedOnMainThread: Bool?
        var stateUpdatedOnMainThread: Bool?
        var scanned: DeepScanReport?
        let finished = expectation(description: "扫描完成并按 issue #21 的模式回主线程更新状态")

        scheduler.runScan {
            scannedOnMainThread = Thread.isMainThread
            scanStarted.signal()
            // 等调用线程做完一段工作。扫描真跑在调用线程（主线程）上时，这里会死锁，
            // 用例随即超时失败——这正是 issue #21 那个「界面冻住 3 秒」的形态。
            _ = callingThreadWorked.wait(timeout: .now() + 20)
            scanned = scanner.scan(tools: [tool], rules: [rule], homeDirectory: fixture.rootPath)
            scheduler.runOnMain {
                stateUpdatedOnMainThread = Thread.isMainThread
                finished.fulfill()
            }
        }

        XCTAssertEqual(
            scanStarted.wait(timeout: .now() + 20),
            .success,
            "扫描工作必须立刻被排到后台；同步跑在调用线程上时这里永远等不到"
        )

        // 调用线程（主线程）在扫描进行中继续执行自己的代码——它不可能被挡住的证据就是这段代码真的跑了。
        var callingThreadProgress = 0
        for _ in 0..<10_000 { callingThreadProgress += 1 }
        callingThreadWorked.signal()

        wait(for: [finished], timeout: 60)

        XCTAssertFalse(scannedOnMainThread ?? true, "扫描必须不在主线程上执行（issue #21 的根因）")
        XCTAssertTrue(stateUpdatedOnMainThread ?? false, "状态更新必须回主线程（界面只能在主线程更新）")
        XCTAssertGreaterThan(callingThreadProgress, 0, "扫描期间调用线程必须能继续工作")
        XCTAssertEqual(
            scanned?.totalOccupancy,
            Occupancy(bytes: manifest.shape.totalBytes, fileCount: manifest.shape.totalFileCount),
            "换到后台执行不改变扫描结果"
        )
    }

    // MARK: - 验收 3：保留量不随文件数线性膨胀

    func test汇总条目不随文件数线性膨胀() throws {
        // 两棵**同形状**、只差文件数（5 倍）的树。
        var smallShape = ScaleTreeFixture.Shape()
        smallShape.shardCount = 10
        smallShape.smallFilesPerBucket = 200
        smallShape.largeFiles = []

        var largeShape = ScaleTreeFixture.Shape()
        largeShape.shardCount = 10
        largeShape.smallFilesPerBucket = 1_000
        largeShape.largeFiles = []

        let small = try makeDomain(named: "cardinality-small", shape: smallShape)
        defer { small.fixture.remove() }
        let large = try makeDomain(named: "cardinality-large", shape: largeShape)
        defer { large.fixture.remove() }

        let smallReport = try XCTUnwrap(small.scan().toolReports.first)
        let largeReport = try XCTUnwrap(large.scan().toolReports.first)

        XCTAssertEqual(
            largeReport.occupancy.fileCount,
            smallReport.occupancy.fileCount * 5,
            "对照组：文件数确实涨了 5 倍"
        )

        // 深扫只保留「(类别, 锚点) → 字节数 / 文件数」的计数器，不留文件清单：
        // 文件数涨 5 倍，报告的条目数必须一模一样。
        XCTAssertEqual(
            summaries(largeReport).map(\.subpath).sorted(),
            summaries(smallReport).map(\.subpath).sorted(),
            "同形状的树，无论多少文件，汇总的锚点集合都不该变"
        )
        XCTAssertEqual(
            summaries(largeReport).count,
            summaries(smallReport).count,
            "汇总条数与文件数无关"
        )
        XCTAssertLessThanOrEqual(
            summaries(largeReport).count,
            4,
            "上界：本形状声明了两个锚点（sessions / .tmp），四类各自最多一条"
        )

        // 唯一按条数增长的只有「读不到」与「没跟随的链接」两份清单——干净树里它们都是空的。
        XCTAssertEqual(largeReport.unreadable, [])
        XCTAssertEqual(largeReport.unfollowedLinks, [])
    }

    // MARK: - 验收 4：访问范围只在已确认工具的工具根内

    func test规模树下访问范围只落在已确认工具的工具根内() throws {
        let fixture = try ScaleTreeFixture(named: "access-scope")
        defer { fixture.remove() }

        var shape = ScaleTreeFixture.Shape()
        shape.shardCount = 20
        shape.smallFilesPerBucket = 100
        _ = try fixture.build(shape)
        let (tool, rule) = try fixture.tool(for: shape)

        // 受保护的真实目标（PRD §14.5 的形状：工具根下的链接指向共享技能目录）。
        let sharedSkills = try fixture.write("shared-apps/skills/SKILL.md", bytes: 300)
        try fixture.makeSymbolicLink(".codex/skills", to: sharedSkills.deletingLastPathComponent().path)
        // 工具根之外、又不受保护的位置：一次都不该被访问（PRD §8.2）。
        let movies = try fixture.write("movies/巨大的视频.bin", bytes: 100_000)
        try fixture.makeSymbolicLink(".codex/sessions/link-out", to: movies.deletingLastPathComponent().path)

        let recorder = RecordingDiscoveryFileSystem()
        _ = DeepScanner(fileSystem: recorder).scan(
            tools: [tool],
            rules: [rule],
            homeDirectory: fixture.rootPath
        )

        XCTAssertEqual(recorder.writeAttempts, [], "深扫全程零写入：\(recorder.writeSummary)")
        XCTAssertEqual(
            recorder.accesses.filter { if case .header = $0 { return true } else { return false } },
            [],
            "只读元数据：不读文件头"
        )

        // 记录到的访问里，工具根之外的只允许「受保护链接的真实目标」一处。
        let toolRoot = tool.toolRootPath
        let outside = recorder.touchedPaths.filter { !$0.hasPrefix(toolRoot + "/") && $0 != toolRoot }
        XCTAssertFalse(outside.isEmpty, "对照组：这棵树里确实有工具根之外的受保护目标被读过")
        XCTAssertTrue(
            outside.allSatisfy { $0 == sharedSkills.deletingLastPathComponent().path || $0 == sharedSkills.path },
            "工具根之外只允许碰受保护链接的真实目标；实际碰到：\(outside)"
        )

        // 不得列举主目录（issue #19 的纪律在深扫里继续成立），也不得碰外部媒体库。
        XCTAssertFalse(
            recorder.accesses.contains(.listed(fixture.rootPath)),
            "受保护判定不得列举主目录：\n\(recorder.summary)"
        )
        XCTAssertEqual(
            recorder.touched(underOrEqual: movies.deletingLastPathComponent().path),
            [],
            "指向工具根之外、又不受保护的链接一律拒绝处理：一个字节都不读（PRD §8.2）"
        )

        // 每个条目恰好读一次元数据（逐文件一次 lstat）：既不多看，也不重复看。
        let stats = recorder.accesses.compactMap { access -> String? in
            if case let .stat(path) = access { return path }
            return nil
        }
        // 受保护链接的目标目录本身不会被 stat：深扫是直接进入它（列举），
        // 逐条读取的是它里面的条目——这正是「不跟随链接、只读目标内容」的形态。
        let expectedStats = Set(
            [toolRoot]
                + fixture.entryPaths(underToolRootRelative: shape.toolRootName)
                + [sharedSkills.path]
        )
        XCTAssertEqual(
            stats.count,
            expectedStats.count,
            "每个条目恰好读一次元数据（重复读盘是 scale 题里的浪费）：\(recorder.summary)"
        )
        XCTAssertEqual(Set(stats), expectedStats, "读元数据的范围必须正好是树上的条目（含受保护链接目标）")
    }

    // MARK: - 规模下的符号链接与权限错误

    func test规模树下符号链接与权限错误仍按目录粒度隔离() throws {
        let fixture = try ScaleTreeFixture(named: "scale-errors")
        defer { fixture.remove() }

        var shape = ScaleTreeFixture.Shape()
        shape.shardCount = 20
        shape.smallFilesPerBucket = 500
        shape.largeFiles = [
            (relativePath: "sessions/2026/10/15/rollout-big.jsonl.zst", bytes: 2_553_000_000)
        ]
        let manifest = try fixture.build(shape)
        let (tool, rule) = try fixture.tool(for: shape)

        // 两个读不到的目录：各藏一个 5,000 字节的文件，谁也统计不到。
        try fixture.write(".codex/.tmp/locked-a/hidden.jsonl", bytes: 5_000)
        let lockedA = try fixture.lockDirectory(".codex/.tmp/locked-a")
        try fixture.write(".codex/sessions/locked-b/hidden.jsonl", bytes: 5_000)
        let lockedB = try fixture.lockDirectory(".codex/sessions/locked-b")
        defer {
            fixture.unlock(lockedA)
            fixture.unlock(lockedB)
        }

        // 一条指向受保护目标的链接（目标 300 字节算进受保护）与一条指向外部媒体库的链接。
        let sharedSkills = try fixture.write("shared-apps/skills/SKILL.md", bytes: 300)
        try fixture.makeSymbolicLink(".codex/skills", to: sharedSkills.deletingLastPathComponent().path)
        let movies = try fixture.write("movies/巨大的视频.bin", bytes: 100_000)
        try fixture.makeSymbolicLink(".codex/.tmp/link-out", to: movies.deletingLastPathComponent().path)

        let recorder = RecordingDiscoveryFileSystem()
        let report = try XCTUnwrap(
            DeepScanner(fileSystem: recorder)
                .scan(tools: [tool], rules: [rule], homeDirectory: fixture.rootPath)
                .toolReports.first
        )

        // 读得到的部分照常精确统计（两个 locked 目录里的文件一个都没算进来）。
        XCTAssertEqual(
            report.category(.archivableSession)?.occupancy,
            Occupancy(bytes: manifest.sessionBytes, fileCount: manifest.sessionFileCount),
            "可归档会话的统计不受两个读不到的目录影响"
        )
        XCTAssertEqual(
            report.category(.cacheAndLog)?.occupancy,
            Occupancy(bytes: manifest.cacheBytes, fileCount: manifest.cacheFileCount)
        )

        // 读不到的位置按目录粒度隔离列出：只有那两个目录，其余一个不少。
        XCTAssertEqual(
            report.unreadable.map(\.relativePath).sorted(),
            [".tmp/locked-a", "sessions/locked-b"],
            "读不到的目录要单独列出（PRD §4.4）"
        )
        XCTAssertTrue(report.unreadable.allSatisfy { $0.kind == .directory })
        XCTAssertTrue(
            report.unreadable.allSatisfy { ($0.reason ?? "").isEmpty == false },
            "要给出可读的原因，界面才能引导用户去系统设置：\(report.unreadable.map(\.reason))"
        )

        // 两条链接都没被跟随，且如实标明目标在不在工具根内。
        XCTAssertEqual(
            report.unfollowedLinks.map(\.relativePath).sorted(),
            [".tmp/link-out", "skills"]
        )
        XCTAssertEqual(
            report.unfollowedLinks.first { $0.relativePath == "skills" }?.isInsideToolRoot,
            false,
            "受保护的共享技能目录在工具根之外"
        )
        XCTAssertEqual(
            report.unfollowedLinks.first { $0.relativePath == ".tmp/link-out" }?.isInsideToolRoot,
            false
        )
        XCTAssertEqual(
            recorder.touched(underOrEqual: movies.deletingLastPathComponent().path),
            [],
            "不受保护的外部链接目标一次都不该被访问：\n\(recorder.summary)"
        )
        XCTAssertEqual(recorder.writeAttempts, [], "零写入")
    }
}

/// 每次目录列举睡一会儿的文件系统替身（issue #29）。
///
/// 只有「扫描有没有被排到后台」这一条断言需要它：把扫描窗口拉长到几十毫秒，
/// 调用线程是否被挡住才有可观察的差别。它不改任何读取结果。
private final class SlowDirectoryListingFileSystem: DiscoveryFileSystem, @unchecked Sendable {

    private let wrapped: any DiscoveryFileSystem
    private let delay: TimeInterval

    init(wrapped: any DiscoveryFileSystem, delay: TimeInterval) {
        self.wrapped = wrapped
        self.delay = delay
    }

    func entryNames(inDirectory path: String) throws -> [String] {
        Thread.sleep(forTimeInterval: delay)
        return try wrapped.entryNames(inDirectory: path)
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
