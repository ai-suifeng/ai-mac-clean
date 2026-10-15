import Foundation

import AIMacCleanDomain
import AIMacCleanRules
import XCTest

/// 让规则夹具先过一遍**规则集准入**（Seam 2）再交给发现器（issue #11）。
///
/// 发现器只消费**已验证可用**的规则集，因此任何想拿发现器做断言的用例都该从这里取规则。
/// 放在 Support 里而不是某个测试文件里，是因为「内置规则集」是多个 seam 共用的入口：
/// 发现器用它断言候选，接缝测试用它断言出厂规则本身。
func admittedBundledRules() throws -> [ToolRule] {
    let directory = try XCTUnwrap(BuiltInRuleResources.directory, "内置规则应当是 bundle 资源。")
    let load = RuleLoader.loadRules(inDirectory: directory)
    XCTAssertEqual(load.diagnostics.map(\.errorDescription), [], "内置规则必须全部读得进来。")
    let report = RuleSetAdmission.admit(rules: load.rules, homeDirectory: NSTemporaryDirectory())
    XCTAssertTrue(report.rejections.isEmpty, "内置规则不该被准入拒绝：\(report.rejections)")
    return report.usableRules
}

/// 规则夹具先过一遍规则集准入（issue #11）：发现器只消费**已验证可用**的规则集。
func admittedRules(_ ruleJSON: [String]) throws -> [ToolRule] {
    let rules = try ruleJSON.map { try RuleLoader.loadRule(from: Data($0.utf8), source: "夹具") }
    let report = RuleSetAdmission.admit(rules: rules, homeDirectory: NSTemporaryDirectory())
    XCTAssertTrue(report.rejections.isEmpty, "夹具规则不该被准入拒绝：\(report.rejections)")
    return report.usableRules
}
