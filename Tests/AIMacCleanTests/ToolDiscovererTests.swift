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
}

// MARK: - 辅助

/// 规则夹具先过一遍规则集准入（issue #11）：发现器只消费**已验证可用**的规则集。
private func admittedRules(_ ruleJSON: [String]) throws -> [ToolRule] {
    let rules = try ruleJSON.map { try RuleLoader.loadRule(from: Data($0.utf8), source: "夹具") }
    let report = RuleSetAdmission.admit(rules: rules, homeDirectory: NSTemporaryDirectory())
    XCTAssertTrue(report.rejections.isEmpty, "夹具规则不该被准入拒绝：\(report.rejections)")
    return report.usableRules
}
