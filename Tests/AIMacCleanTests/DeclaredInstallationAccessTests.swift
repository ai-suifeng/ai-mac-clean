import Foundation
import XCTest

import AIMacCleanDomain
import AIMacCleanRules

/// issue #19 验收 2：安装检测**只 stat 规则声明过的安装路径**。
///
/// 做法是**对照实验**：同一条规则跑两遍，唯一差别是有没有 `installations` 声明。
/// 两份访问记录必须只差「声明条数」那么多条 `stat`，而且**一条列举都不许多**
/// ——枚举 `/Applications`、PATH 目录正是用户两次反馈的那个缺陷。
final class DeclaredInstallationAccessTests: XCTestCase {

    /// **验收 2**：没有安装声明的工具不产生安装佐证，也不产生任何额外目录访问；
    /// 有声明但路径不存在的工具同样如此，并且多出来的访问恰好是逐条 `stat`。
    func test没有安装声明的工具不产生安装佐证也不产生任何额外访问() throws {
        let fixture = try DiscoveryFixture(named: "declared-install-access")
        defer { fixture.home.remove() }

        try fixture.makeFile(
            ".local/share/opencode/storage/-Users-xiaowei-amc-wt-19/session/message/"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.json"
        )

        struct Run {
            let candidate: Candidate
            let accesses: [RecordingDiscoveryFileSystem.Access]
        }

        func record(_ ruleJSON: String) throws -> Run {
            let recorder = RecordingDiscoveryFileSystem()
            let result = ToolDiscoverer(
                rules: try admittedRules([ruleJSON]),
                fileSystem: recorder,
                homeDirectory: fixture.homePath
            ).discover()
            return Run(candidate: try XCTUnwrap(result.candidates.first), accesses: recorder.accesses)
        }

        let without = try record(Self.opencodeRule)
        let declared = try record(Self.opencodeRuleWithInstallations)

        // 没有声明：只有结构指纹，停在「中」，没有任何安装佐证。
        XCTAssertEqual(without.candidate.confidence, .medium)
        XCTAssertTrue(
            without.candidate.signals.externalCorroborations.isEmpty,
            "没有安装声明就不该凭空出现佐证：\(without.candidate.signals.externalCorroborations)"
        )

        // 声明了但路径不存在：同样不产生佐证、不升档，也不报错。
        XCTAssertEqual(declared.candidate.confidence, .medium)
        XCTAssertTrue(
            declared.candidate.signals.externalCorroborations.isEmpty,
            "声明路径不存在只是「没有安装佐证」：\(declared.candidate.signals.externalCorroborations)"
        )

        // 对照：多出来的访问**恰好**是对两条声明路径的逐条 stat。
        XCTAssertEqual(
            Array(declared.accesses.prefix(2)),
            [
                .stat(fixture.homePath + "/Applications/Opencode.app"),
                .stat("/opt/homebrew/bin/opencode-is-not-there"),
            ],
            "安装检测只能是对声明路径逐条 stat：\n\(declared.accesses)"
        )
        XCTAssertEqual(
            Array(declared.accesses.dropFirst(2)), without.accesses,
            "多一条安装声明只该多一次 stat，其余访问必须逐条相同：\n\(declared.accesses)"
        )

        // 声明路径的**父目录**也不许被列举：那不是规则声明的工具根。
        for directory in [
            fixture.homePath + "/Applications",
            "/opt/homebrew/bin",
            fixture.homePath,
        ] {
            XCTAssertFalse(
                declared.accesses.contains(.listed(directory)),
                "\(directory) 不是规则声明的工具根，一次发现都不该列举它：\n\(declared.accesses)"
            )
        }
    }

    /// 一条没有安装声明的规则：OpenCode 的形态（只认 `storage/` 目录）。
    private static let opencodeRule = """
    {
      "schemaVersion": 1,
      "id": "opencode",
      "displayName": "OpenCode",
      "roots": [{ "path": "~/.local/share/opencode", "role": "toolRoot" }],
      "structuralFingerprint": { "sessionDirectoryShapes": ["storage"] }
    }
    """

    /// 同一条规则，只多两条安装声明（都不存在）。
    private static let opencodeRuleWithInstallations = """
    {
      "schemaVersion": 1,
      "id": "opencode",
      "displayName": "OpenCode",
      "roots": [{ "path": "~/.local/share/opencode", "role": "toolRoot" }],
      "installations": [
        { "path": "~/Applications/Opencode.app", "kind": "appBundle" },
        { "path": "/opt/homebrew/bin/opencode-is-not-there", "kind": "executable" }
      ],
      "structuralFingerprint": { "sessionDirectoryShapes": ["storage"] }
    }
    """
}
