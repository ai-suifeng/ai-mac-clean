import Foundation
import XCTest

import AIMacCleanDomain
@testable import AIMacCleanUI

/// Seam G：发现与确认页的视图模型（issue #16）。
///
/// 这是本页唯一被断言的 seam：候选怎么摆、决定怎么落盘、折叠与可访问性文案怎么算。
/// 视图本身保持很薄——所有状态都在这里，视图只做渲染。
final class DiscoveryPageModelTests: XCTestCase {

    private var fixture: DiscoveryPageFixture!

    override func setUpWithError() throws {
        fixture = try DiscoveryPageFixture()
    }

    // MARK: - 分档与折叠（User Stories 3、4）

    func test候选按高中西分组且顺序固定() throws {
        let model = try makeModel(candidates: [
            .fixtureCandidate(confidence: .low, pathSuffix: "low"),
            .fixtureCandidate(confidence: .medium, pathSuffix: "medium"),
            .fixtureCandidate(confidence: .high, pathSuffix: "high"),
        ])

        XCTAssertEqual(model.state.pendingGroups.map(\.tier), [.high, .medium, .low])
    }

    func test疑似候选默认折叠高置信度默认展开() throws {
        let model = try makeModel(candidates: [
            .fixtureCandidate(confidence: .high, pathSuffix: "high"),
            .fixtureCandidate(confidence: .medium, pathSuffix: "medium"),
            .fixtureCandidate(confidence: .low, pathSuffix: "low"),
        ])

        let expandedByTier = Dictionary(
            uniqueKeysWithValues: model.state.pendingGroups.map { ($0.tier, $0.isExpanded) }
        )
        XCTAssertEqual(expandedByTier[.high], true)
        XCTAssertEqual(expandedByTier[.medium], true)
        XCTAssertEqual(expandedByTier[.low], false, "纯名称命中的「疑似」候选默认必须折叠（User Story 4）")
    }

    func test用户展开疑似分组后重新加载仍保持展开() throws {
        let model = try makeModel(candidates: [.fixtureCandidate(confidence: .low, pathSuffix: "low")])

        model.toggleExpanded(for: .low)
        XCTAssertEqual(model.state.pendingGroups.first?.isExpanded, true)

        model.reload()
        XCTAssertEqual(model.state.pendingGroups.first?.isExpanded, true, "重新扫描不该把用户手动展开的分组又折回去")
    }

    func test没有候选的分档不出现() throws {
        let model = try makeModel(candidates: [.fixtureCandidate(confidence: .high, pathSuffix: "high")])

        XCTAssertEqual(model.state.pendingGroups.map(\.tier), [.high])
    }

    func test没有候选时给出空列表而不是报错() throws {
        // User Story 13：没装任何 AI 工具不是错误。
        let model = try makeModel(candidates: [])

        XCTAssertEqual(model.state.pendingGroups, [])
        XCTAssertTrue(model.state.hasLoaded)
        XCTAssertNil(model.state.lastActionFailure)
    }

    // MARK: - 辅助

    /// 造一个已经跑过一次发现的模型（等价于视图挂载时的 `load()`）。
    private func makeModel(candidates: [Candidate], unreadable: [UnreadableDirectory] = [], issues: [DiscoveryIssue] = []) throws -> DiscoveryPageModel {
        let model = DiscoveryPageModel(
            source: StubDiscoverySource(
                run_: DiscoveryRun(
                    result: DiscoveryResult(candidates: candidates, unreadableDirectories: unreadable),
                    issues: issues
                )
            ),
            store: fixture.store,
            settings: fixture.settings,
            homeDirectory: fixture.homePath,
            now: { DiscoveryPageFixture.decisionTime }
        )
        model.load()
        return model
    }
}

extension Candidate {
    /// 测试里造候选的简写。
    static func fixtureCandidate(
        confidence: ConfidenceTier,
        pathSuffix: String = "tool",
        isSuspicious: Bool? = nil,
        signals: ConfirmationSignals = .none,
        demotions: [CandidateDemotion] = []
    ) -> Candidate {
        Candidate(
            toolRootPath: "/tmp/fake-home/.\(pathSuffix)",
            displayPath: "~/.\(pathSuffix)",
            ruleIdentifier: "claude-code",
            ruleDisplayName: "Claude Code",
            confidence: confidence,
            isSuspicious: isSuspicious ?? (confidence == .low),
            signals: signals,
            demotions: demotions
        )
    }
}
