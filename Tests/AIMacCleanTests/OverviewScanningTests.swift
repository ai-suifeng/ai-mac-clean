import XCTest

import AIMacCleanDomain
import AIMacCleanUI

/// issue #28 验收 6（沿用 issue #21 的纪律）：重新扫描不清空、不卡界面。
///
/// 断言的是**可观察行为**：`load()` 立即返回、工作交给调度器、扫描期间上一轮结果
/// 原样留在界面上、重复点击不排队第二次扫描、放行后换成新结果。
final class OverviewScanningTests: XCTestCase {

    /// 手动调度器：扫描工作被攒下来，由测试决定何时放行。
    private final class ManualScheduler {
        private(set) var pendingScans: [() -> Void] = []

        var scheduler: DiscoveryScheduler {
            DiscoveryScheduler(
                runScan: { [weak self] work in self?.pendingScans.append(work) },
                // 状态更新同步执行：测试要的是「放行之后立刻能断言」。
                runOnMain: { $0() }
            )
        }

        func runNextScan() {
            guard !pendingScans.isEmpty else { return }
            pendingScans.removeFirst()()
        }
    }

    private func report(archivableBytes: Int64) -> DeepScanReport {
        OverviewFixture.report([
            OverviewFixture.toolReport(
                id: "claude-code",
                displayName: "Claude Code",
                toolRootPath: "/tmp/fake-home/.claude",
                bytes: [.archivableSession: archivableBytes],
                fileCounts: [.archivableSession: 1]
            ),
        ])
    }

    private func makeModel(
        scheduler: DiscoveryScheduler,
        scanner: StubOccupancyScanner
    ) throws -> (model: OverviewPageModel, fixture: OverviewPageFixture) {
        let fixture = try OverviewPageFixture(named: "overview-scanning")
        try fixture.confirm(id: "claude-code", root: fixture.toolRoot(".claude"))
        let model = OverviewPageModel(
            store: fixture.store,
            scanner: scanner,
            capacityReader: StubCapacityReader(reading: .measured(availableBytes: 1_024, totalBytes: 2_048)),
            homeDirectory: fixture.homePath,
            issueSource: StubIssueSource(),
            scheduler: scheduler
        )
        return (model, fixture)
    }

    func test重新扫描立即返回并把工作交给调度器() throws {
        let manual = ManualScheduler()
        let (model, fixture) = try makeModel(
            scheduler: manual.scheduler,
            scanner: StubOccupancyScanner(report: report(archivableBytes: 1_048_576))
        )
        defer { fixture.remove() }

        let started = Date()
        model.load()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.05, "load() 必须立即返回——同步深扫就是界面卡死的原因")
        XCTAssertTrue(model.state.isScanning)
        XCTAssertFalse(model.state.hasLoaded, "扫描还没完成")
        XCTAssertEqual(manual.pendingScans.count, 1, "扫描工作交给调度器，而不是就地执行")
    }

    func test重新扫描期间上一轮结果保持可见且界面可交互() throws {
        let manual = ManualScheduler()
        let scanner = StubOccupancyScanner(report: report(archivableBytes: 1_048_576))
        let (model, fixture) = try makeModel(scheduler: manual.scheduler, scanner: scanner)
        defer { fixture.remove() }

        model.load()
        manual.runNextScan()
        let firstRows = model.toolRows
        XCTAssertEqual(firstRows.map(\.occupancyText), ["1 MB（1 个文件）"])

        scanner.reportFor = { _ in self.report(archivableBytes: 2_097_152) }
        model.reload()

        XCTAssertTrue(model.state.isScanning)
        XCTAssertEqual(model.toolRows, firstRows, "重新扫描期间上一轮结果必须保持可见，不许清空")
        XCTAssertEqual(model.totalText, "总占用：1 MB（1 个文件）")
        XCTAssertEqual(model.freeSpaceText, "磁盘剩余空间：1 KB（共 2 KB）")

        // 界面仍可交互：扫描中再点一次只是被忽略，不排队、不清屏。
        model.reload()
        XCTAssertEqual(manual.pendingScans.count, 1)

        manual.runNextScan()
        XCTAssertFalse(model.state.isScanning)
        XCTAssertEqual(model.toolRows.map(\.occupancyText), ["2 MB（1 个文件）"])
    }

    func test首次扫描期间没有结果也不显示0() throws {
        let manual = ManualScheduler()
        let (model, fixture) = try makeModel(
            scheduler: manual.scheduler,
            scanner: StubOccupancyScanner(report: report(archivableBytes: 1_048_576))
        )
        defer { fixture.remove() }

        model.load()

        XCTAssertTrue(model.state.isScanning)
        XCTAssertNil(model.totalText, "第一次扫描还没回来：宁可什么都不显示，也不显示 0")
        XCTAssertFalse(model.isEmpty, "有已确认工具，这不是空状态")
        XCTAssertNotNil(model.scanningText)
    }

    /// 已确认工具变了（例如用户刚在发现页确认了一台），上一轮的数字就不再对应现在这批工具。
    /// 扫描期间宁可什么都不显示，也不许把一个属于别人的 0 摆出来。
    func test已确认工具变了之后扫描期间不显示上一轮的数字() throws {
        let manual = ManualScheduler()
        let (model, fixture) = try makeModel(
            scheduler: manual.scheduler,
            scanner: StubOccupancyScanner(report: report(archivableBytes: 1_048_576))
        )
        defer { fixture.remove() }

        model.load()
        manual.runNextScan()
        XCTAssertEqual(model.totalText, "总占用：1 MB（1 个文件）")

        // 用户刚确认了第二台工具：工具集合变了。
        try fixture.confirm(id: "codex-cli", root: fixture.toolRoot(".codex"))
        model.reload()

        XCTAssertTrue(model.state.isScanning)
        XCTAssertNil(model.totalText, "旧数字对应的是上一批工具，扫描期间不许拿它充数")
        XCTAssertFalse(model.isEmpty)

        manual.runNextScan()
        XCTAssertNotNil(model.totalText, "新结果回来之后照常显示")
    }

    // MARK: - 生产调度器

    /// 扫描与容量读取都要在调用线程（主线程）之外完成。
    func test生产调度器把扫描与容量读取都放到主线程之外() throws {
        let fixture = try OverviewPageFixture(named: "overview-background")
        defer { fixture.remove() }
        try fixture.confirm(id: "claude-code", root: fixture.toolRoot(".claude"))

        final class ProbeScanner: ConfirmedToolScanning {
            let called: XCTestExpectation
            let report: DeepScanReport
            private(set) var ranOffMainThread = false

            init(called: XCTestExpectation, report: DeepScanReport) {
                self.called = called
                self.report = report
            }

            func scan(_ records: [ConfirmationRecord]) -> DeepScanReport {
                ranOffMainThread = !Thread.isMainThread
                called.fulfill()
                return report
            }
        }

        final class ProbeCapacityReader: VolumeCapacityReading {
            let called: XCTestExpectation
            private(set) var ranOffMainThread = false

            init(called: XCTestExpectation) { self.called = called }

            func capacity(ofVolumeContaining path: String) -> VolumeCapacity {
                ranOffMainThread = !Thread.isMainThread
                called.fulfill()
                return .measured(availableBytes: 1_000, totalBytes: 2_000)
            }
        }

        let scanCalled = expectation(description: "深扫跑过了")
        let capacityCalled = expectation(description: "容量读过了")
        let scanner = ProbeScanner(called: scanCalled, report: report(archivableBytes: 1_048_576))
        let reader = ProbeCapacityReader(called: capacityCalled)
        let model = OverviewPageModel(
            store: fixture.store,
            scanner: scanner,
            capacityReader: reader,
            homeDirectory: fixture.homePath,
            issueSource: StubIssueSource(),
            scheduler: .background()
        )

        model.load()
        XCTAssertTrue(model.state.isScanning, "load() 在后台扫描开始前就返回了")

        wait(for: [scanCalled, capacityCalled], timeout: 5)
        XCTAssertTrue(scanner.ranOffMainThread, "深扫不能在主线程上跑")
        XCTAssertTrue(reader.ranOffMainThread, "容量读取同样不能在主线程上跑")
    }
}
