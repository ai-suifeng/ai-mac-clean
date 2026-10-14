import XCTest

@testable import AIMacCleanUI

/// Seam F：本地化结构（issue #16；User Stories 39、40）。
///
/// 本阶段文案先以中文落地（PRD §9「中文/英文」的落地方式），
/// 但**结构必须能加第二种语言**：因此断言的是「两套目录各自覆盖同一批 key」，
/// 而不是断言某一句具体文案。
final class LocalizationCatalogTests: XCTestCase {

    func test每个key在中文与英文目录下都能取到文案() {
        for key in L10n.Key.allCases {
            let zh = L10n.text(key, language: .simplifiedChinese)
            let en = L10n.text(key, language: .english)
            XCTAssertNotEqual(zh, key.rawValue, "中文目录缺少 key：\(key.rawValue)")
            XCTAssertNotEqual(en, key.rawValue, "英文目录缺少 key：\(key.rawValue)")
            XCTAssertFalse(zh.isEmpty)
            XCTAssertFalse(en.isEmpty)
        }
    }

    func test中文与英文目录的key集合完全一致() {
        let zhKeys = Set(L10n.catalogKeys(language: .simplifiedChinese))
        let enKeys = Set(L10n.catalogKeys(language: .english))
        XCTAssertFalse(zhKeys.isEmpty, "中文目录读不出来")
        XCTAssertEqual(zhKeys, enKeys, "两种语言的 key 集合不一致，加语言时就会漏词")
    }

    func test代码里登记的key不多于目录里的key() {
        // 目录里多出未登记的 key（手工加词但忘了加枚举）会被这条断言抓住。
        let zhKeys = Set(L10n.catalogKeys(language: .simplifiedChinese))
        for key in zhKeys where L10n.Key(rawValue: key) == nil {
            XCTFail("目录里有未登记的 key：\(key)")
        }
    }

    func test系统默认语言下也能取到中文文案() {
        // 兜底纪律：任何语言都取不到时必须落到中文，而不是把 key 本身显示给用户。
        let text = L10n.text(.discoveryPageTitle)
        XCTAssertFalse(text.isEmpty)
        XCTAssertNotEqual(text, L10n.Key.discoveryPageTitle.rawValue)
    }

    /// 「忘掉这条记录」是可逆的，GLOSSARY 里的「移除」是唯一的不可逆动作。
    /// 因此文案与 key 都不能沿用 remove / 移除。
    func test忘记记录的动作不叫移除而叫移出列表() {
        let zh = L10n.text(.discoveryActionForget, language: .simplifiedChinese)
        let en = L10n.text(.discoveryActionForget, language: .english)

        XCTAssertEqual(zh, "移出列表")
        XCTAssertEqual(en, "Forget")
        for key in L10n.catalogKeys(language: .simplifiedChinese) + L10n.catalogKeys(language: .english) {
            XCTAssertNotEqual(
                key, "discovery.action.remove",
                "旧的 discovery.action.remove 必须整个消失，不能只改文案留着 key"
            )
        }
    }
}
