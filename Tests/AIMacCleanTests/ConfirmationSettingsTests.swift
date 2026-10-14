import XCTest

@testable import AIMacCleanDomain

/// 设置项（PRD §10：「设置用 UserDefaults」）。
///
/// 与确认记录不同，设置刻意走 UserDefaults 而不是自己写 JSON。
/// 测试必须用**独立 suite**，绝不能写进应用真实的 defaults 域（PRD §13 第 3 条）。
final class ConfirmationSettingsTests: XCTestCase {

    private var 套件名: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        套件名 = "ai-mac-clean.tests.settings.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: 套件名))
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: 套件名)
        defaults = nil
        套件名 = nil
    }

    func test纯名称命中的候选默认折叠() throws {
        let 设置 = try XCTUnwrap(ConfirmationSettings(defaults: defaults))

        // User Story 4 / PRD §4.3：纯名称命中的候选一律标为「疑似」并默认折叠。
        XCTAssertTrue(设置.collapsesNameOnlyCandidates)
    }

    func test设置写入独立套件并被新实例读回() throws {
        let 设置 = try XCTUnwrap(ConfirmationSettings(defaults: defaults))
        设置.collapsesNameOnlyCandidates = false
        设置.hasCompletedFirstLaunchReview = true

        // 新实例读回：设置也必须活过一次「重启」。
        let 重启后 = try XCTUnwrap(ConfirmationSettings(defaults: defaults))
        XCTAssertFalse(重启后.collapsesNameOnlyCandidates)
        XCTAssertTrue(重启后.hasCompletedFirstLaunchReview)

        // 值落在注入的套件里，而不是应用自己的 defaults 域。
        defaults.synchronize()
        let 套件域 = try XCTUnwrap(UserDefaults.standard.persistentDomain(forName: 套件名))
        XCTAssertNotNil(套件域["collapsesNameOnlyCandidates"])
        XCTAssertNotNil(套件域["hasCompletedFirstLaunchReview"])
    }
}
