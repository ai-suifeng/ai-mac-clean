import Foundation
import XCTest

@testable import AIMacCleanRules

/// GLOSSARY 的禁用同义词护栏（review 修复）。
///
/// GLOSSARY「受保护」把「锁定」列为 _Avoid_（锁定是另一种状态），「归档」与「移除」
/// 把「删除」列为 _Avoid_（太宽泛，且抹掉了「移除以归档校验通过为前提」这层意思）。
/// 这些词很容易在改写注释时悄悄溜回**随包分发的规则文件**与**面向用户的拒绝原因**里，
/// 因此用一条测试把它们钉住：护栏只覆盖会出厂的东西，不覆盖 GLOSSARY 与 PRD 本身
/// （它们是词表与需求来源，本来就要写出被禁用的词来解释它）。
final class GlossarySynonymGuardTests: XCTestCase {

    /// 随包出厂的文案里不允许出现的同义词，以及它们各自的解释来源。
    private static let avoidedSynonyms: [String: String] = [
        "锁定": "GLOSSARY「受保护」的 _Avoid_：锁定是另一种状态；「不确定」只展示占用",
        "删除": "GLOSSARY「归档」/「移除」的 _Avoid_：太宽泛，未体现以归档校验通过为前提",
    ]

    // MARK: - 内置规则文件

    func test内置规则文件的备注与展示名不含GLOSSARY的禁用同义词() throws {
        let directory = try XCTUnwrap(BuiltInRuleResources.directory, "内置规则应当是 bundle 资源。")
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertFalse(files.isEmpty, "内置规则目录里没有 JSON 规则文件。")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (synonym, reason) in Self.avoidedSynonyms {
                XCTAssertFalse(
                    text.contains(synonym),
                    "\(file.lastPathComponent) 用了禁用同义词「\(synonym)」——\(reason)。"
                )
            }
        }
    }

    func test解码后的内置规则分类备注不含GLOSSARY的禁用同义词() throws {
        let directory = try XCTUnwrap(BuiltInRuleResources.directory, "内置规则应当是 bundle 资源。")
        let load = RuleLoader.loadRules(inDirectory: directory)
        XCTAssertEqual(load.diagnostics.map(\.errorDescription), [], "内置规则必须全部读得进来。")

        for rule in load.rules {
            let texts = [rule.displayName] + rule.classification.compactMap(\.note)
            for text in texts {
                for (synonym, reason) in Self.avoidedSynonyms {
                    XCTAssertFalse(
                        text.contains(synonym),
                        "规则 \(rule.id) 的文案用了禁用同义词「\(synonym)」：\(text)——\(reason)。"
                    )
                }
            }
        }
    }

    // MARK: - 面向用户的诊断文本

    func test拒绝原因与准入诊断不含GLOSSARY的禁用同义词() throws {
        let home = NSTemporaryDirectory()

        let monotonicity = ProtectionMonotonicityViolation(
            field: "classification[0].category",
            pattern: "auth.json",
            declaredCategory: .archivableSession,
            protectedRuleIdentifier: "codex-cli/auth",
            protectedScopeDescription: "codex-cli 工具根下的 auth*"
        )
        let uncertain = UncertainDowngrade(
            field: "classification[0].category",
            pattern: "*.pb",
            uncertainShapeIdentifier: "uncertain/protobuf"
        )

        let texts: [String] = [
            monotonicity.description,
            uncertain.description,
            DataCategory.uncertain.displayText,
        ] + ProtectedRegionFactory.regions(forToolRoot: home + "/.codex", homeDirectory: home).map(\.scopeDescription)
            + ProtectionMonotonicity.uncertainRegions(forToolRoot: home + "/.codex").map(\.scopeDescription)

        for text in texts {
            for (synonym, reason) in Self.avoidedSynonyms {
                XCTAssertFalse(
                    text.contains(synonym),
                    "面向用户的诊断文本用了禁用同义词「\(synonym)」：\(text)——\(reason)。"
                )
            }
        }
        // 顺手钉住它真的在讲「移除以归档校验通过为前提」，而不是一句空话。
        XCTAssertTrue(monotonicity.description.contains("归档"), monotonicity.description)
        XCTAssertTrue(uncertain.description.contains("仅展示占用"), uncertain.description)
    }
}
