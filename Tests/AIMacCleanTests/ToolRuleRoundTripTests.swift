import XCTest

@testable import AIMacCleanRules

/// Seam R3：往返序列化（issue #10 的验收「写入 → 读出 → 再序列化结果等价」）。
final class ToolRuleRoundTripTests: XCTestCase {

    func test四套实测形状的规则往返后等价() throws {
        for source in [RuleFixtures.claudeCodeJSON, RuleFixtures.codexJSON,
                       RuleFixtures.cursorJSON, RuleFixtures.harnessJSON] {
            let first = try ToolRule.decode(from: Data(source.utf8))

            let encoded = try first.encoded()
            let second = try ToolRule.decode(from: encoded)
            let reencoded = try second.encoded()

            XCTAssertEqual(encoded, reencoded, "再次序列化应产生同样的字节")
            XCTAssertEqual(first, second, "往返后模型应等价")
        }
    }

    func test往返后字段值不变() throws {
        let original = try ToolRule.decode(from: Data(RuleFixtures.codexJSON.utf8))
        let restored = try ToolRule.decode(from: try original.encoded())

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.roots, original.roots)
        XCTAssertEqual(restored.structuralFingerprint, original.structuralFingerprint)
        XCTAssertEqual(restored.cascade, original.cascade)
        XCTAssertEqual(restored.projectPathEncoding, original.projectPathEncoding)
        XCTAssertEqual(restored.classification, original.classification)
        XCTAssertEqual(restored.selfCompressed, original.selfCompressed)
        XCTAssertEqual(restored.sessionFileNaming, original.sessionFileNaming)
        XCTAssertEqual(restored.installations, original.installations)
    }

    func test序列化是确定性的() throws {
        let rule = try ToolRule.decode(from: Data(RuleFixtures.claudeCodeJSON.utf8))
        XCTAssertEqual(try rule.encoded(), try rule.encoded())
    }

    func test省略的可选字段在往返后仍然省略() throws {
        let json = """
        {"schemaVersion":1,"id":"x","displayName":"X","roots":[{"path":"/tmp/x"}]}
        """
        let rule = try ToolRule.decode(from: Data(json.utf8))
        let restored = try ToolRule.decode(from: try rule.encoded())

        XCTAssertNil(restored.structuralFingerprint)
        XCTAssertNil(restored.projectPathEncoding)
        XCTAssertNil(restored.sessionFileNaming)
        XCTAssertEqual(restored.cascade, [])
        XCTAssertEqual(restored.classification, [])
        XCTAssertFalse(restored.selfCompressed)
    }
}
