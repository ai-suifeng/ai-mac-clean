import XCTest

import AIMacCleanDomain
import AIMacCleanUI

/// issue #21：点「重新扫描」不应把界面冻住。
///
/// 一次发现要遍历工具根、读会话文件头，本机实测约 3 秒。原先把这段工作同步跑在调用线程
/// （主线程）上，用户点一下按钮窗口就卡住。这里断言的是**可观察行为**：调用立即返回、
/// 期间状态可读、完成后状态更新、重复点击不排队第二次扫描。
final class DiscoveryScanningTests: XCTestCase {

    /// 手动调度器：扫描工作被攒下来，由测试决定何时放行。
    private final class ManualScheduler {
        private(set) var pendingScans: [() -> Void] = []

        var scheduler: DiscoveryScheduler {
            DiscoveryScheduler(
                runScan: { [weak self] work in self?.pendingScans.append(work) },
                // 状态更新同步执行：测试要的是「放行之后立刻能断言」，而不是真去等主队列。
                runOnMain: { $0() }
            )
        }

        func runNextScan() {
            guard !pendingScans.isEmpty else { return }
            pendingScans.removeFirst()()
        }
    }

    private func makeModel(
        scheduler: DiscoveryScheduler,
        run: DiscoveryRun
    ) throws -> (model: DiscoveryPageModel, fixture: DiscoveryPageFixture) {
        let fixture = try DiscoveryPageFixture(named: "scanning")
        let model = DiscoveryPageModel(
            source: StubDiscoverySource(run_: run),
            store: fixture.store,
            settings: fixture.settings,
            homeDirectory: fixture.homePath,
            scheduler: scheduler
        )
        return (model, fixture)
    }

    func test重新扫描立即返回且期间处于扫描中状态() throws {
        let manual = ManualScheduler()
        let (model, _) = try makeModel(
            scheduler: manual.scheduler,
            run: DiscoveryRun(result: DiscoveryResult())
        )

        let started = Date()
        model.reload()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.05, "reload() 必须立即返回——同步扫描就是界面卡死的原因")
        XCTAssertTrue(model.state.isScanning, "扫描期间界面要能知道自己在扫描")
        XCTAssertFalse(model.state.hasLoaded, "扫描还没完成")
        XCTAssertEqual(manual.pendingScans.count, 1, "扫描工作被交给调度器，而不是就地执行")
    }

    func test扫描完成后状态更新且不再处于扫描中() throws {
        let manual = ManualScheduler()
        let (model, _) = try makeModel(
            scheduler: manual.scheduler,
            run: DiscoveryRun(
                result: DiscoveryResult(candidates: [.fixtureCandidate(confidence: .high, pathSuffix: "claude")])
            )
        )

        model.reload()
        XCTAssertTrue(model.state.pendingGroups.isEmpty, "还没放行，候选不该出现")

        manual.runNextScan()

        XCTAssertFalse(model.state.isScanning)
        XCTAssertTrue(model.state.hasLoaded)
        XCTAssertEqual(model.state.pendingGroups.flatMap(\.candidates).count, 1)
    }

    func test扫描进行中重复点击不会排队第二次扫描() throws {
        let manual = ManualScheduler()
        let (model, _) = try makeModel(
            scheduler: manual.scheduler,
            run: DiscoveryRun(result: DiscoveryResult())
        )

        model.reload()
        model.reload()
        model.reload()

        XCTAssertEqual(manual.pendingScans.count, 1, "连点（或连按 ⌘R）只应产生一次扫描")

        manual.runNextScan()
        model.reload()
        XCTAssertEqual(manual.pendingScans.count, 1, "上一次扫描结束后才允许再扫一次")
    }

    func test生产调度器把扫描放到主线程之外并把状态更新放回主线程() {
        let scheduler = DiscoveryScheduler.background()

        let scanOffMain = expectation(description: "扫描不在主线程")
        scheduler.runScan {
            XCTAssertFalse(Thread.isMainThread, "3 秒的 I/O 不能占用主线程")
            scanOffMain.fulfill()
        }

        let updateOnMain = expectation(description: "状态更新回主线程")
        scheduler.runOnMain {
            XCTAssertTrue(Thread.isMainThread)
            updateOnMain.fulfill()
        }

        wait(for: [scanOffMain, updateOnMain], timeout: 5)
    }

    func test同步调度器在返回前就完成扫描() throws {
        let (model, _) = try makeModel(
            scheduler: .immediate,
            run: DiscoveryRun(result: DiscoveryResult())
        )

        model.reload()

        XCTAssertTrue(model.state.hasLoaded, "同步调度器下返回即完成（测试与确定性场景）")
        XCTAssertFalse(model.state.isScanning)
    }
}
