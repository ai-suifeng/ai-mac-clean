import Foundation
import XCTest

import AIMacCleanDomain

/// 发现与确认页的测试替身：一个**固定**的发现结果。
///
/// 视图模型的测试不跑文件系统扫描——扫描本身由 `ToolDiscovererTests` 在 Seam 1 上钉住，
/// 这里只关心「拿到候选之后，界面状态机怎么摆它们」。
struct StubDiscoverySource: DiscoverySource {

    var run_: DiscoveryRun

    func run() -> DiscoveryRun { run_ }
}

/// 发现与确认页夹具：临时目录上的确认存储 + 假主目录 + 假候选。
///
/// 确认存储跑在真实临时文件上（spec #7 §持久化：不为持久化单开 seam），
/// 「重启后不再询问」这类断言因此是端到端的：换一个模型实例就是换了「一次重启」。
final class DiscoveryPageFixture {

    let applicationSupport: TemporaryDirectoryFixture
    let home: TemporaryDirectoryFixture
    let store: JSONConfirmationStore
    let defaults: UserDefaults
    let settings: ConfirmationSettings?
    let homePath: String

    init(named name: String = "discovery-page") throws {
        applicationSupport = try TemporaryDirectoryFixture(named: name + "-store")
        home = try TemporaryDirectoryFixture(named: name + "-home")
        store = JSONConfirmationStore(applicationSupportRoot: applicationSupport.url)
        homePath = home.url.path
        // 设置必须写进独立 suite，绝不能污染应用真实的 defaults 域（PRD §13 第 3 条）。
        let suite = "ai-mac-clean.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = ConfirmationSettings(defaults: defaults)
    }

    /// 夹具里的假主目录下建目录，返回绝对路径。
    @discardableResult
    func makeToolRoot(_ relativePath: String) throws -> String {
        try home.makeDirectory(relativePath).path
    }

    /// 一个固定的「用户动作时刻」，避免断言依赖墙上时钟。
    static let decisionTime = Date(timeIntervalSince1970: 1_700_000_000)
}
