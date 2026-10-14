import Foundation

import AIMacCleanDomain
import AIMacCleanRules
import XCTest

/// Seam 1 — 发现管线（issue #12 / spec #7 §发现管线）。
///
/// 断言只落在**外部可观察行为**上：哪些目录进了候选、置信度多少、哪些目录被跳过并说明。
/// 不断言打分权重、不断言遍历顺序、不断言内部数据结构形状。
final class ToolDiscovererTests: XCTestCase {

    // MARK: - 切片 1：空结果不是错误（User Story 13）

    func test空目录树返回空候选列表且不报错() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        let discoverer = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.claudeCodeJSON]),
            homeDirectory: fixture.homePath
        )

        let result = discoverer.discover(scanRoots: ScanRoot.standard(forHomeDirectory: fixture.homePath))

        XCTAssertTrue(result.candidates.isEmpty, "没装任何 AI 工具时应给出空列表，而不是报错或塞进噪声目录")
        XCTAssertTrue(result.unreadableDirectories.isEmpty)
    }
    // MARK: - 切片 2：结构指纹才准入（User Story 8、9）

    func test命中结构指纹的工具根进候选而名字像没结构的目录不进候选() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        // 实测形状：`projects/<单横线编码路径>/<uuid>.jsonl`，另有旧版子代理转录 `agent-*.jsonl`。
        try fixture.makeFile(".claude/projects/-Users-xiaowei-amc-wt-12/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl")
        try fixture.makeFile(".claude/projects/-Users-xiaowei-amc-wt-12/agent-1c2d3e4f-5a6b-7c8d-9e0f-1a2b3c4d5e6f.jsonl")
        // 名字里含 claude，但没有任何结构（PRD A1 的反面教材）。
        try fixture.makeFile("claude-something/readme.md", contents: "# 不是工具数据")

        let discoverer = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.claudeCodeJSON]),
            homeDirectory: fixture.homePath
        )

        let result = discoverer.discover()

        XCTAssertEqual(result.candidates.map(\.toolRootPath), [fixture.homePath + "/.claude"])
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.ruleIdentifier, "claude-code")
        XCTAssertTrue(
            candidate.signals.structuralFingerprints.contains("projects/<encodedPath>/<uuid>.jsonl"),
            "准入依据必须是结构指纹，实际命中：\(candidate.signals.structuralFingerprints)"
        )
    }
}

// MARK: - 辅助

/// 规则夹具先过一遍规则集准入（issue #11）：发现器只消费**已验证可用**的规则集。
private func admittedRules(_ ruleJSON: [String]) throws -> [ToolRule] {
    let rules = try ruleJSON.map { try RuleLoader.loadRule(from: Data($0.utf8), source: "夹具") }
    let report = RuleSetAdmission.admit(rules: rules, homeDirectory: NSTemporaryDirectory())
    XCTAssertTrue(report.rejections.isEmpty, "夹具规则不该被准入拒绝：\(report.rejections)")
    return report.usableRules
}
