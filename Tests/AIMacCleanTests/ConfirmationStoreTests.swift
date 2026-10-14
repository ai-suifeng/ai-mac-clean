import XCTest

@testable import AIMacCleanDomain

/// 确认存储（issue #13）。
///
/// 断言方式：只经过 `ConfirmationStore` 这个公开接口进出，
/// 并且每次「重启」都是**用同一根目录新开一个 store 实例**重新读盘，
/// 不读取实例的内存状态，也不做任何仓储替身（spec #7「持久化」：不为存储单开测试 seam）。
/// 所有写入都发生在注入的临时目录根下，绝不触碰真实 Application Support。
final class ConfirmationStoreTests: XCTestCase {

    private var fixture: TemporaryDirectoryFixture!

    override func setUpWithError() throws {
        fixture = try TemporaryDirectoryFixture(named: "confirmation-store")
    }

    override func tearDown() {
        fixture.remove()
        fixture = nil
    }

    // MARK: - 辅助

    /// 临时目录下的一个工具根目录路径，形状照抄本机实测（GLOSSARY「工具根目录」）。
    private func 工具根(_ 名字: String) -> String {
        fixture.url.appendingPathComponent(名字, isDirectory: true).path
    }

    // MARK: - 确认记录持久化

    func test确认记录写入后在新实例里被读回() throws {
        let 决定时刻 = Date(timeIntervalSince1970: 1_760_000_000)
        let 根路径 = 工具根(".claude")
        let 信号 = ConfirmationSignals(
            structuralFingerprints: ["projects/<uuid>.jsonl"],
            nameMatches: ["claude"],
            externalCorroborations: [.application("Claude.app")]
        )

        let 写入方 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        try 写入方.decide(
            toolIdentifier: "claude-code",
            toolRootPath: 根路径,
            decision: .confirmed,
            signals: 信号,
            decidedAt: 决定时刻
        )

        // 模拟重启：同一根目录，全新的 store 实例，从磁盘重新读。
        let 重启后 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        let 记录 = try XCTUnwrap(重启后.record(forToolRootPath: 根路径))

        XCTAssertEqual(记录.toolIdentifier, "claude-code")
        XCTAssertEqual(记录.toolRootPath, 根路径)
        XCTAssertEqual(记录.decision, .confirmed)
        XCTAssertEqual(记录.decidedAt, 决定时刻)
        XCTAssertEqual(记录.signals, 信号)
    }

    // MARK: - 忽略

    func test忽略的候选重启后不再需要询问() throws {
        let 忽略路径 = 工具根(".claudebak")

        let 写入方 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        try 写入方.decide(
            toolIdentifier: nil,
            toolRootPath: 忽略路径,
            decision: .ignored,
            signals: ConfirmationSignals(nameMatches: ["claude"]),
            decidedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )

        // 下次启动：候选里同时有已忽略的、有已确认的、有全新的，只有全新的还要问。
        let 重启后 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        let 待询问 = 重启后.pendingToolRootPaths(
            amongCandidates: [忽略路径, 工具根(".codex"), 工具根(".cursor")]
        )

        XCTAssertEqual(待询问, [工具根(".codex"), 工具根(".cursor")])
    }

    func test确认过的工具也不在待确认候选里() throws {
        let 已确认路径 = 工具根(".codex")

        let 写入方 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        try 写入方.decide(
            toolIdentifier: "codex-cli",
            toolRootPath: 已确认路径,
            decision: .confirmed,
            signals: ConfirmationSignals(
                structuralFingerprints: ["sessions/YYYY/MM/DD/rollout-*.jsonl"]
            ),
            decidedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )

        let 重启后 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        XCTAssertEqual(重启后.pendingToolRootPaths(amongCandidates: [已确认路径]), [])
        XCTAssertEqual(重启后.confirmedTools.map(\.toolRootPath), [已确认路径])
        XCTAssertTrue(重启后.ignoredCandidates.isEmpty)
    }

    // MARK: - 移出列表（忘掉记录）与加回

    /// 「忘掉这条记录」是完全可逆的：GLOSSARY 里的「移除」是**唯一不可逆**的动作，
    /// 且以归档校验通过为前提。API 因此不能叫 `removeTool`——名字会把一条可逆操作
    /// 说成不可逆的那一步。
    func test忘掉一条记录的入口叫forget而不是remove() throws {
        let 根路径 = 工具根(".cursor")
        let 写入方 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        try 写入方.decide(
            toolIdentifier: "cursor",
            toolRootPath: 根路径,
            decision: .confirmed,
            signals: ConfirmationSignals.none,
            decidedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )

        XCTAssertTrue(try 写入方.forgetTool(atToolRootPath: 根路径))
        XCTAssertNil(写入方.record(forToolRootPath: 根路径))
        // 没有记录就是「没忘掉过」，两次调用应当如实报告。
        XCTAssertFalse(try 写入方.forgetTool(atToolRootPath: 根路径))
    }

    func test移出已确认工具后重启读回时不在列表里() throws {
        let 根路径 = 工具根(".cursor")

        let 写入方 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        try 写入方.decide(
            toolIdentifier: "cursor",
            toolRootPath: 根路径,
            decision: .confirmed,
            signals: ConfirmationSignals(structuralFingerprints: ["globalStorage/state.vscdb"]),
            decidedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )

        try 写入方.forgetTool(atToolRootPath: 根路径)

        // 重启后它既不在已确认列表里，也不再有记录——移出列表是让记录不再存在，
        // 不是改写成「忽略」。
        let 重启后 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        XCTAssertNil(重启后.record(forToolRootPath: 根路径))
        XCTAssertTrue(重启后.confirmedTools.isEmpty)
        XCTAssertTrue(重启后.ignoredCandidates.isEmpty)
    }

    func test移出后重新加回又出现在已确认列表里() throws {
        let 根路径 = 工具根(".cursor")
        let 加回时刻 = Date(timeIntervalSince1970: 1_760_100_000)

        let 写入方 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        try 写入方.decide(
            toolIdentifier: "cursor",
            toolRootPath: 根路径,
            decision: .confirmed,
            signals: ConfirmationSignals.none,
            decidedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
        try 写入方.forgetTool(atToolRootPath: 根路径)
        try 写入方.decide(
            toolIdentifier: "cursor",
            toolRootPath: 根路径,
            decision: .confirmed,
            signals: ConfirmationSignals(structuralFingerprints: ["globalStorage/state.vscdb"]),
            decidedAt: 加回时刻
        )

        let 重启后 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        let 记录 = try XCTUnwrap(重启后.confirmedTools.first)
        XCTAssertEqual(记录.toolRootPath, 根路径)
        XCTAssertEqual(记录.decidedAt, 加回时刻)
    }

    func test误点的忽略可以改回确认() throws {
        let 根路径 = 工具根(".local/share/opencode")
        let 改回时刻 = Date(timeIntervalSince1970: 1_760_200_000)

        let 写入方 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        try 写入方.decide(
            toolIdentifier: "opencode",
            toolRootPath: 根路径,
            decision: .ignored,
            signals: ConfirmationSignals(nameMatches: ["opencode"]),
            decidedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )

        // 改主意：同一个工具根目录再做一次「确认是 AI 工具」的决定。
        let 改回后 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        try 改回后.decide(
            toolIdentifier: "opencode",
            toolRootPath: 根路径,
            decision: .confirmed,
            signals: ConfirmationSignals(
                structuralFingerprints: ["storage/session/<uuid>.json"]
            ),
            decidedAt: 改回时刻
        )

        let 重启后 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        let 记录 = try XCTUnwrap(重启后.record(forToolRootPath: 根路径))
        XCTAssertEqual(记录.decision, .confirmed)
        XCTAssertEqual(记录.decidedAt, 改回时刻)
        // 信号跟着最新的判断走，而不是留着当初忽略时的理由。
        XCTAssertEqual(记录.signals.structuralFingerprints, ["storage/session/<uuid>.json"])
        XCTAssertEqual(重启后.confirmedTools.map(\.toolRootPath), [根路径])
        XCTAssertTrue(重启后.ignoredCandidates.isEmpty)
    }

    // MARK: - 信号

    func test三类信号在重启后分别可读() throws {
        let 根路径 = 工具根(".codex")

        let 写入方 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        try 写入方.decide(
            toolIdentifier: "codex-cli",
            toolRootPath: 根路径,
            decision: .confirmed,
            signals: ConfirmationSignals(
                structuralFingerprints: [
                    "sessions/YYYY/MM/DD/rollout-*.jsonl",
                    "archived_sessions/*.jsonl.zst",
                ],
                nameMatches: ["codex"],
                externalCorroborations: [
                    .application("Codex.app"),
                    .command("codex"),
                    .contentFeature("首行含 type/cwd 字段"),
                ]
            ),
            decidedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )

        let 重启后 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        let 信号 = try XCTUnwrap(重启后.record(forToolRootPath: 根路径)).signals

        XCTAssertEqual(信号.structuralFingerprints, [
            "sessions/YYYY/MM/DD/rollout-*.jsonl",
            "archived_sessions/*.jsonl.zst",
        ])
        XCTAssertEqual(信号.nameMatches, ["codex"])
        XCTAssertEqual(信号.externalCorroborations, [
            .application("Codex.app"),
            .command("codex"),
            .contentFeature("首行含 type/cwd 字段"),
        ])
    }

    // MARK: - 重复决定

    func test重复确认同一工具只保留一条记录() throws {
        let 根路径 = 工具根(".claude")
        let 首次 = Date(timeIntervalSince1970: 1_760_000_000)
        let 再次 = Date(timeIntervalSince1970: 1_760_300_000)

        let 写入方 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        try 写入方.decide(
            toolIdentifier: "claude-code",
            toolRootPath: 根路径,
            decision: .confirmed,
            signals: ConfirmationSignals(nameMatches: ["claude"]),
            decidedAt: 首次
        )
        try 写入方.decide(
            toolIdentifier: "claude-code",
            toolRootPath: 根路径,
            decision: .confirmed,
            signals: ConfirmationSignals(structuralFingerprints: ["projects/<uuid>.jsonl"]),
            decidedAt: 再次
        )

        let 重启后 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        XCTAssertEqual(重启后.confirmedTools.count, 1)
        let 记录 = try XCTUnwrap(重启后.record(forToolRootPath: 根路径))
        XCTAssertEqual(记录.decidedAt, 再次)
        XCTAssertEqual(记录.signals.nameMatches, [])
    }

    func test尾随分隔符与点路径归一到同一条记录() throws {
        let 根路径 = 工具根(".codex")

        let 写入方 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        try 写入方.decide(
            toolIdentifier: "codex-cli",
            toolRootPath: 根路径 + "/",
            decision: .confirmed,
            signals: ConfirmationSignals.none,
            decidedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )

        let 重启后 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        // 发现管线给出的路径形态可能有尾随分隔符或 `.` 段；那是同一个工具根目录，不该变成两条记录。
        let 另一形态 = 根路径 + "/./"
        XCTAssertEqual(重启后.record(forToolRootPath: 另一形态)?.toolRootPath, 根路径)
        XCTAssertEqual(重启后.confirmedTools.count, 1)
        XCTAssertEqual(重启后.pendingToolRootPaths(amongCandidates: [另一形态]), [])
    }

    // MARK: - 读不出来时不动它

    func test存储文件损坏时读不出记录且拒绝覆盖原文件() throws {
        // 模拟一个被外力写坏（或来自更高版本）的存储文件。
        let 目录 = fixture.url.appendingPathComponent(JSONConfirmationStore.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: 目录, withIntermediateDirectories: true)
        let 文件 = 目录.appendingPathComponent(JSONConfirmationStore.fileName)
        let 损坏内容 = Data("{ \"schemaVersion\": 1, \"records\": [".utf8)
        try 损坏内容.write(to: 文件)

        let store = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        XCTAssertNotNil(store.loadFailure)
        // 读不出来就是读不出来：不能凭空造一份空记录假装一切正常。
        XCTAssertTrue(store.confirmedTools.isEmpty)
        XCTAssertNil(store.record(forToolRootPath: 工具根(".codex")))

        // 写必须被拒绝——用户的判断可能还能从备份里救回来，覆盖掉就彻底没了。
        XCTAssertThrowsError(
            try store.decide(
                toolIdentifier: "codex-cli",
                toolRootPath: 工具根(".codex"),
                decision: .confirmed,
                signals: ConfirmationSignals.none,
                decidedAt: Date()
            )
        ) { 错误 in
            guard case .storeUnreadable = 错误 as? ConfirmationStoreError else {
                return XCTFail("期望 storeUnreadable，实际：\(错误)")
            }
        }
        XCTAssertThrowsError(try store.forgetTool(atToolRootPath: 工具根(".codex")))
        XCTAssertEqual(try Data(contentsOf: 文件), 损坏内容, "损坏的存储文件必须原样保留")
    }

    // MARK: - 注入点

    func test记录只写在注入的根目录下() throws {
        let 根路径 = 工具根(".codex")

        let 写入方 = JSONConfirmationStore(applicationSupportRoot: fixture.url)
        try 写入方.decide(
            toolIdentifier: "codex-cli",
            toolRootPath: 根路径,
            decision: .confirmed,
            signals: ConfirmationSignals.none,
            decidedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )

        let 期望文件 = fixture.url
            .appendingPathComponent(JSONConfirmationStore.directoryName, isDirectory: true)
            .appendingPathComponent(JSONConfirmationStore.fileName)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: 期望文件.path),
            "记录必须落在注入的 Application Support 根下"
        )

        // 换一个临时根：读不到刚才的记录。状态只属于被注入的那个根，
        // 没有跑到机器上任何共享位置去——尤其是真实的 ~/Library/Application Support。
        let 另一个根 = try TemporaryDirectoryFixture(named: "confirmation-store-other-root")
        defer { 另一个根.remove() }
        let 别处 = JSONConfirmationStore(applicationSupportRoot: 另一个根.url)

        XCTAssertNil(别处.record(forToolRootPath: 根路径))
        XCTAssertTrue(别处.confirmedTools.isEmpty)
        // 仅仅打开一个空存储不创建任何目录或文件。
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: 另一个根.url
                    .appendingPathComponent(JSONConfirmationStore.directoryName)
                    .path
            )
        )
    }
}
