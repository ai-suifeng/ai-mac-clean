import Foundation
import XCTest

import AIMacCleanDomain

@testable import AIMacCleanUI

/// Seam：分类明细页的**状态机**（issue #27）。
///
/// 视图只渲染 `ClassificationDetailPageState`；所有会出错的状态都在视图模型里：
/// 扫描中、上一轮结果、空态、规则不可用。深扫本身由 `DeepScanServiceTests` 与
/// `DeepScanningTests` 在各自的 seam 上钉住，这里给**固定结果**，不碰磁盘。
final class ClassificationDetailPageModelTests: XCTestCase {

    /// 固定的深扫结果源。
    private final class StubSource: DeepScanSource {
        var run_: DeepScanRun
        init(_ run_: DeepScanRun) { self.run_ = run_ }
        func run() -> DeepScanRun { run_ }
    }

    /// 手动调度器：把「扫描」与「回主线程更新」两段工作扣在手里，
    /// 用来断言扫描期间界面到底处于什么状态。
    private final class ManualScheduler {
        private var scanWork: (() -> Void)?
        private var mainWork: (() -> Void)?
        private(set) var scanRequestCount = 0

        var scheduler: DiscoveryScheduler {
            DiscoveryScheduler(
                runScan: { [weak self] work in
                    self?.scanRequestCount += 1
                    self?.scanWork = work
                },
                runOnMain: { [weak self] work in self?.mainWork = work }
            )
        }

        /// 跑完一次扫描：先跑扫描本身，再跑它排回主线程的状态更新。
        func finishScan() {
            let scan = scanWork
            scanWork = nil
            scan?()
            let update = mainWork
            mainWork = nil
            update?()
        }
    }

    private func makeModel(
        _ source: DeepScanSource,
        scheduler: DiscoveryScheduler = .immediate
    ) -> ClassificationDetailPageModel {
        ClassificationDetailPageModel(
            source: source,
            homeDirectory: "/Users/example",
            scheduler: scheduler
        )
    }

    private func twoToolReport() -> DeepScanReport {
        DeepScanReport(toolReports: [
            ClassificationDetailFixture.claudeCode(),
            ClassificationDetailFixture.report(
                toolID: "codex-cli",
                displayName: "Codex CLI",
                toolRootPath: "/Users/example/.codex",
                categories: [
                    ClassificationDetailFixture.category(
                        .archivableSession,
                        bytes: ClassificationDetailFixture.bytes(7168),
                        files: 792
                    )
                ]
            ),
        ])
    }

    // MARK: - 正常路径

    func test固定的深扫结果摊成每台工具一份明细() {
        let model = makeModel(StubSource(DeepScanRun(report: twoToolReport())))
        model.load()

        XCTAssertTrue(model.state.hasLoaded)
        XCTAssertFalse(model.state.isScanning)
        XCTAssertEqual(model.state.details.map(\.toolID), ["claude-code", "codex-cli"])
        XCTAssertEqual(model.state.details.count, 2)
        XCTAssertEqual(
            model.state.details.first?.row(.protected)?.sizeText, "270 MB",
            "明细直接来自深扫结果，视图模型不重算占用"
        )
        XCTAssertEqual(model.detail(toolID: "codex-cli")?.totalSizeText, "7 GB")
    }

    // MARK: - 验收：扫描在后台跑，界面不被阻塞

    func test扫描交给调度器而不在调用线程上跑() {
        let scheduler = ManualScheduler()
        let model = makeModel(StubSource(DeepScanRun(report: twoToolReport())), scheduler: scheduler.scheduler)

        model.load()

        XCTAssertEqual(scheduler.scanRequestCount, 1, "扫描被交给调度器（生产是后台队列）")
        XCTAssertTrue(model.state.isScanning, "扫描进行中：状态如实说「正在扫描」")
        XCTAssertTrue(model.state.details.isEmpty, "第一次扫描还没有结果，此时不显示任何数字")
    }

    func test重新扫描期间保留上一轮结果不清空成空白() {
        let scheduler = ManualScheduler()
        let source = StubSource(DeepScanRun(report: twoToolReport()))
        let model = makeModel(source, scheduler: scheduler.scheduler)

        model.load()
        scheduler.finishScan()
        XCTAssertEqual(model.state.details.count, 2)

        // 工具被卸载后的重扫：结果为空，但扫描期间界面必须继续显示上一轮。
        source.run_ = DeepScanRun()
        model.reload()
        XCTAssertTrue(model.state.isScanning)
        XCTAssertEqual(model.state.details.count, 2, "扫描中不清空上一轮结果")

        scheduler.finishScan()
        XCTAssertFalse(model.state.isScanning)
        XCTAssertTrue(model.state.details.isEmpty, "扫描完成后才反映真实结果")
    }

    func test扫描进行中重复调用不会排队第二次扫描() {
        let scheduler = ManualScheduler()
        let model = makeModel(StubSource(DeepScanRun(report: twoToolReport())), scheduler: scheduler.scheduler)

        model.load()
        model.load()
        model.reload()

        XCTAssertEqual(scheduler.scanRequestCount, 1, "扫描进行中重复点「重新扫描」不再排一次")
    }

    // MARK: - 空态与问题

    func test没有已确认工具时给出引导性空态() {
        let model = makeModel(StubSource(DeepScanRun()))
        model.load()

        XCTAssertTrue(model.state.isEmpty)
        XCTAssertEqual(
            model.emptyText,
            "还没有确认过任何工具。先到「发现与确认」页确认 AI 工具，这里才会按类别列出占用。"
        )
        XCTAssertTrue(model.issueTexts.isEmpty, "空态与规则出问题是两回事，不混在一句话里")
    }

    func test没有可用规则时说出原因而不是显示零占用() {
        let model = makeModel(StubSource(DeepScanRun(issues: [.noUsableRules(rejectedCount: 4)])))
        model.load()

        XCTAssertTrue(model.state.details.isEmpty)
        XCTAssertFalse(model.state.isEmpty, "有问题的空结果不是「还没确认过工具」")
        XCTAssertEqual(model.issueTexts, [
            "加载到 4 条规则，但全部未通过规则集准入（保护单调性校验），无法判定分类。",
        ])
    }

    func test一条规则都没加载到时的文案点明是配置问题() {
        let model = makeModel(StubSource(DeepScanRun(issues: [.noRulesLoaded])))
        model.load()

        XCTAssertEqual(model.issueTexts, [
            "没有加载到任何内置规则文件，无法判定分类，因此这里不显示占用。请确认打包时把规则资源一并放进了应用包。",
        ])
    }

    // MARK: - 文案

    func test页面文案全部走本地化() {
        let model = makeModel(StubSource(DeepScanRun()))

        XCTAssertEqual(model.titleText, "分类明细")
        XCTAssertEqual(model.reloadTitleText, "重新扫描")
        XCTAssertEqual(model.scanningText, "正在扫描…（只读元数据与文件头，不动任何文件）")
        XCTAssertEqual(
            model.stageNoteText,
            "当前版本只读元数据，不会移动或删除任何文件；四类占用都只展示。归档能力在后续里程碑。"
        )
        XCTAssertEqual(model.titleText, L10n.text(.classificationPageTitle, language: .simplifiedChinese))
    }
}
