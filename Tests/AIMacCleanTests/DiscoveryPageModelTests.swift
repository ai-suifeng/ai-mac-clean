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

    // MARK: - 确认与忽略的落盘（User Stories 15、16、19）

    func test确认后候选不再待确认且进入已确认列表() throws {
        let signals = ConfirmationSignals(
            structuralFingerprints: ["projects/<uuid>.jsonl"],
            nameMatches: ["claude"],
            externalCorroborations: [.application("Claude")]
        )
        let model = try makeModel(candidates: [
            .fixtureCandidate(confidence: .high, pathSuffix: "claude", signals: signals),
        ])

        model.confirm(toolRootPath: "/tmp/fake-home/.claude")

        XCTAssertEqual(model.state.pendingGroups, [])
        XCTAssertEqual(model.state.confirmedTools.map(\.displayPath), ["~/.claude"])
        XCTAssertNil(model.state.lastActionFailure)
    }

    func test确认记录保留当时命中的信号() throws {
        // User Story 19：几个月后还看得懂当初为什么这么判。
        let signals = ConfirmationSignals(
            structuralFingerprints: ["projects/<uuid>.jsonl"],
            nameMatches: ["claude"],
            externalCorroborations: [.command("claude")]
        )
        let model = try makeModel(candidates: [
            .fixtureCandidate(confidence: .high, pathSuffix: "claude", signals: signals),
        ])

        model.confirm(toolRootPath: "/tmp/fake-home/.claude")

        let record = try XCTUnwrap(model.state.confirmedTools.first?.record)
        XCTAssertEqual(record.decision, .confirmed)
        XCTAssertEqual(record.signals, signals)
        XCTAssertEqual(record.toolIdentifier, "claude-code")
        XCTAssertEqual(record.decidedAt, DiscoveryPageFixture.decisionTime)
    }

    func test重启后不再询问已确认的候选() throws {
        // 「重启」= 换一个从磁盘重新读盘的存储实例 + 一个新的模型（PRD §4.1 第 4 步）。
        let candidates: [Candidate] = [.fixtureCandidate(confidence: .high, pathSuffix: "claude")]
        try makeModel(candidates: candidates).confirm(toolRootPath: "/tmp/fake-home/.claude")

        let afterRestart = try makeModel(candidates: candidates, store: reopenStore())

        XCTAssertEqual(afterRestart.state.pendingGroups, [])
        XCTAssertEqual(afterRestart.state.confirmedTools.count, 1)
    }

    func test忽略后不再询问并进入已忽略列表() throws {
        let candidates: [Candidate] = [.fixtureCandidate(confidence: .medium, pathSuffix: "tool")]
        let model = try makeModel(candidates: candidates)

        model.ignore(toolRootPath: "/tmp/fake-home/.tool")

        XCTAssertEqual(model.state.pendingGroups, [])
        XCTAssertEqual(model.state.ignoredCandidates.map(\.displayPath), ["~/.tool"])

        let afterRestart = try makeModel(candidates: candidates, store: reopenStore())
        XCTAssertEqual(afterRestart.state.pendingGroups, [], "忽略过的候选下次启动不该再问一次")
    }

    func test加回后候选重新变成待确认() throws {
        // User Story 18：误点「忽略」之后能改主意。
        let candidates: [Candidate] = [.fixtureCandidate(confidence: .medium, pathSuffix: "tool")]
        try makeModel(candidates: candidates).ignore(toolRootPath: "/tmp/fake-home/.tool")

        let model = try makeModel(candidates: candidates, store: reopenStore())
        XCTAssertEqual(model.state.ignoredCandidates.count, 1)

        model.restoreIgnored(toolRootPath: "/tmp/fake-home/.tool")

        XCTAssertEqual(model.state.ignoredCandidates, [])
        XCTAssertEqual(model.state.pendingGroups.flatMap(\.candidates).map(\.toolRootPath), ["/tmp/fake-home/.tool"])
    }

    func test移出后工具离开已确认列表且候选重新待确认() throws {
        // User Story 17：卸载了工具，它不再出现在列表里。
        let candidates: [Candidate] = [.fixtureCandidate(confidence: .high, pathSuffix: "claude")]
        try makeModel(candidates: candidates).confirm(toolRootPath: "/tmp/fake-home/.claude")

        let model = try makeModel(candidates: candidates, store: reopenStore())
        XCTAssertEqual(model.state.confirmedTools.count, 1)

        model.removeConfirmed(toolRootPath: "/tmp/fake-home/.claude")

        XCTAssertEqual(model.state.confirmedTools, [])
        XCTAssertEqual(model.state.pendingGroups.flatMap(\.candidates).map(\.toolRootPath), ["/tmp/fake-home/.claude"])
    }

    func test存储读不出来时拒绝写入并把原因摆在界面上() throws {
        // 已有记录读不出来时，宁可不写，也不能覆盖用户已有的判断。
        let corrupted = fixture.applicationSupport
            .url
            .appendingPathComponent(JSONConfirmationStore.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: corrupted, withIntermediateDirectories: true)
        try "{ 这不是 JSON".write(
            to: corrupted.appendingPathComponent(JSONConfirmationStore.fileName),
            atomically: true,
            encoding: .utf8
        )
        let store = JSONConfirmationStore(applicationSupportRoot: fixture.applicationSupport.url)
        let model = try makeModel(
            candidates: [.fixtureCandidate(confidence: .high, pathSuffix: "claude")],
            store: store
        )

        model.confirm(toolRootPath: "/tmp/fake-home/.claude")

        XCTAssertEqual(model.state.confirmedTools, [], "读不出来的存储不能被写坏后当成成功")
        let failure = try XCTUnwrap(model.state.lastActionFailure)
        XCTAssertFalse(failure.isEmpty)
        XCTAssertEqual(store.confirmedTools, [])
    }

    // MARK: - 权限提示与加载失败（PRD §4.4、User Stories 14、37）

    func test读不到的位置逐条列出具体路径() throws {
        let model = try makeModel(
            candidates: [.fixtureCandidate(confidence: .high, pathSuffix: "claude")],
            unreadable: [
                UnreadableDirectory(path: "/Users/x/Library/Application Support", reason: "权限不足"),
                UnreadableDirectory(path: "/Users/x/.config", reason: "权限不足"),
            ]
        )

        XCTAssertEqual(
            model.state.unreadableDirectories.map(\.path),
            ["/Users/x/Library/Application Support", "/Users/x/.config"],
            "权限提示必须点名是哪些位置没扫到，而不是笼统说一句「权限不足」"
        )
        let texts = model.permissionNoticeTexts
        XCTAssertEqual(texts.count, 2)
        for path in ["/Users/x/Library/Application Support", "/Users/x/.config"] {
            XCTAssertTrue(texts.contains { $0.contains(path) }, "提示里必须出现具体路径：\(path)")
        }
    }

    func test没有读不到的位置时不出现任何权限提示() throws {
        let model = try makeModel(candidates: [.fixtureCandidate(confidence: .high, pathSuffix: "claude")])

        XCTAssertEqual(model.state.unreadableDirectories, [])
        XCTAssertEqual(model.permissionNoticeTexts, [])
    }

    func test权限提示说明不会预先索取完全磁盘访问() throws {
        let model = try makeModel(
            candidates: [],
            unreadable: [UnreadableDirectory(path: "/Users/x/Library/Containers", reason: "权限不足")]
        )

        XCTAssertEqual(model.permissionNoticeTexts.count, 1)
        let footnote = model.permissionNoticeFootnote
        XCTAssertTrue(
            footnote.contains("完全磁盘访问"),
            "提示必须写明本软件不会预先索取完全磁盘访问（User Story 37）"
        )
    }

    func test运行级问题逐条可读() throws {
        let model = try makeModel(
            candidates: [],
            issues: [.noRulesLoaded, .hintsUnavailable(reason: "文件不存在")]
        )

        let texts = model.issueTexts
        XCTAssertEqual(texts.count, 2)
        for text in texts {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("noRulesLoaded"), "不该把代码里的枚举名甩给用户看")
        }
    }

    // MARK: - 辅助功能读出的文字（User Story 42）

    func test候选的辅助功能读出路径与置信度() throws {
        let candidate = Candidate.fixtureCandidate(confidence: .high, pathSuffix: "claude")
        let model = try makeModel(candidates: [candidate])

        let presentation = model.presentation(for: candidate)
        XCTAssertTrue(presentation.accessibilityLabel.contains("~/.claude"))
        XCTAssertTrue(presentation.accessibilityLabel.contains(model.confidenceText(for: .high)))
    }

    func test候选的辅助功能读出信号与疑似标记() throws {
        let candidate = Candidate.fixtureCandidate(
            confidence: .low,
            pathSuffix: "claudebak",
            signals: ConfirmationSignals(structuralFingerprints: ["projects/<uuid>.jsonl"], nameMatches: ["claude"]),
            demotions: [.negativeNamePattern("*bak*")]
        )
        let model = try makeModel(candidates: [candidate])

        let presentation = model.presentation(for: candidate)
        XCTAssertTrue(presentation.isSuspicious)
        XCTAssertTrue(
            presentation.accessibilityValue.contains(L10n.text(.discoverySuspiciousBadge)),
            "「疑似」必须被辅助技术读出来，而不是只靠颜色（User Story 42）"
        )
        XCTAssertTrue(presentation.accessibilityValue.contains("projects/<uuid>.jsonl"))
        XCTAssertTrue(presentation.accessibilityValue.contains("*bak*"))
    }

    func test三档置信度都有独立的文案() throws {
        let model = try makeModel(candidates: [])
        let texts = [ConfidenceTier.high, .medium, .low].map { model.confidenceText(for: $0) }
        XCTAssertEqual(Set(texts).count, 3)
    }

    // MARK: - 键盘可达（User Story 41）

    func test只用键盘就能确认与忽略() throws {
        // 键盘走的是**同一组**模型方法（视图把按键转发到这里），因此不需要鼠标也能走完全流程。
        let candidate = Candidate.fixtureCandidate(confidence: .high, pathSuffix: "claude")
        let model = try makeModel(candidates: [candidate])

        model.performDefaultAction(onToolRootPath: "/tmp/fake-home/.claude")

        XCTAssertEqual(model.state.confirmedTools.map(\.displayPath), ["~/.claude"])
        XCTAssertEqual(model.state.pendingGroups, [])
        XCTAssertNil(model.state.lastActionFailure)
    }

    func test键盘忽略走的是同一个忽略落盘路径() throws {
        let candidates: [Candidate] = [.fixtureCandidate(confidence: .medium, pathSuffix: "tool")]
        let model = try makeModel(candidates: candidates)

        model.performSecondaryAction(onToolRootPath: "/tmp/fake-home/.tool")

        XCTAssertEqual(model.state.ignoredCandidates.count, 1)
        XCTAssertEqual(reopenStore().ignoredCandidates.map(\.toolRootPath), ["/tmp/fake-home/.tool"])
    }

    func test键盘动作对不在列表里的路径是空操作() throws {
        let model = try makeModel(candidates: [.fixtureCandidate(confidence: .high, pathSuffix: "claude")])

        model.performDefaultAction(onToolRootPath: "/tmp/fake-home/.别的东西")
        model.performSecondaryAction(onToolRootPath: "/tmp/fake-home/.别的东西")

        XCTAssertEqual(model.state.confirmedTools, [])
        XCTAssertEqual(model.state.ignoredCandidates, [])
        XCTAssertNil(model.state.lastActionFailure)
    }

    func test两个键盘动作有各自不同的快捷键说明() throws {
        let model = try makeModel(candidates: [])

        let confirm = try XCTUnwrap(model.keyboardShortcut(for: .confirm))
        let ignore = try XCTUnwrap(model.keyboardShortcut(for: .ignore))
        XCTAssertFalse(confirm.isEmpty)
        XCTAssertFalse(ignore.isEmpty)
        XCTAssertNotEqual(confirm, ignore, "两个动作不能共用同一个键")
    }

    // MARK: - 辅助

    /// 「重启」：从同一个磁盘位置重新读一次确认存储。
    private func reopenStore() -> JSONConfirmationStore {
        JSONConfirmationStore(applicationSupportRoot: fixture.applicationSupport.url)
    }

    /// 造一个已经跑过一次发现的模型（等价于视图挂载时的 `load()`）。
    private func makeModel(
        candidates: [Candidate],
        unreadable: [UnreadableDirectory] = [],
        issues: [DiscoveryIssue] = [],
        store: ConfirmationStore? = nil
    ) throws -> DiscoveryPageModel {
        let model = DiscoveryPageModel(
            source: StubDiscoverySource(
                run_: DiscoveryRun(
                    result: DiscoveryResult(candidates: candidates, unreadableDirectories: unreadable),
                    issues: issues
                )
            ),
            store: store ?? fixture.store,
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
