import Foundation

/// 规则文件的测试夹具。
///
/// 形状照抄 PRD §5.4 的本机实测结论，而不是照抄更早的描述——两者在
/// `file-history/` / `todos/` 的存在性上已经不一致（PRD §14.5）。
///
/// **与内置受保护清单对齐**：`shell-snapshots/**`（`claude-code/shell-snapshots`）与
/// `*.sqlite`（`codex-cli/sqlite`）都声明为 `protected`，不是更弱的类别——
/// 规则集准入现在会把「改判成别的类别」当成拒绝理由，夹具必须零拒绝才能被下游测试使用。
///
/// 全部规则只用于解码测试，路径都写在这里的字符串里，不指向真实数据目录。
enum RuleFixtures {

    /// Claude Code：项目路径双横线编码 + 子代理转录 + 版本差异的关联数据。
    static let claudeCodeJSON = """
    {
      "schemaVersion": 1,
      "id": "claude-code",
      "displayName": "Claude Code",
      "roots": [
        { "path": "~/.claude", "role": "toolRoot" }
      ],
      "structuralFingerprint": {
        "sessionFilePatterns": ["projects/<encodedPath>/<uuid>.jsonl"],
        "projectDirectoryShapes": ["projects/<encodedPath>"],
        "fileHeaderKeys": ["type"],
        "headerByteLimit": 4096
      },
      "cascade": [
        { "kind": "siblingTranscripts", "pattern": "agent-<uuid>.jsonl" },
        { "kind": "sessionKeyedDirectory", "pattern": "file-history/<name:sessionID>" },
        { "kind": "sessionKeyedFile", "pattern": "todos/<name:sessionID>-agent-<name:sessionID>.json" }
      ],
      "projectPathEncoding": {
        "scheme": "doubleDash"
      },
      "classification": [
        { "pattern": "projects/<encodedPath>/<uuid>.jsonl", "category": "archivableSession" },
        { "pattern": "projects/<encodedPath>/agent-<uuid>.jsonl", "category": "archivableSession" },
        { "pattern": "file-history/<name:sessionID>", "category": "archivableSession" },
        { "pattern": "settings*.json", "category": "protected" },
        { "pattern": "skills/**", "category": "protected" },
        { "pattern": "commands/**", "category": "protected" },
        { "pattern": "history.jsonl", "category": "protected" },
        { "pattern": "shell-snapshots/**", "category": "protected" }
      ],
      "selfCompressed": false,
      "sessionFileNaming": {
        "stableSessionIdentifier": true,
        "sessionIDSource": "fileName"
      }
    }
    """

    /// Codex CLI：年月日嵌套 + 自带 zstd 压缩 + 扁平归档目录 + fork 双 UUID 文件名 + 项目路径在文件内。
    static let codexJSON = """
    {
      "schemaVersion": 1,
      "id": "codex-cli",
      "displayName": "Codex CLI",
      "roots": [
        { "path": "~/.codex", "role": "toolRoot" }
      ],
      "structuralFingerprint": {
        "sessionFilePatterns": [
          "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl",
          "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl[.zst]",
          "archived_sessions/rollout-<ISO>.jsonl.zst"
        ],
        "sessionDirectoryShapes": ["sessions/<date:year>", "archived_sessions"],
        "fileHeaderKeys": ["type", "payload"],
        "headerByteLimit": 8192
      },
      "cascade": [],
      "projectPathEncoding": {
        "scheme": "inFileField",
        "fieldPath": "session_meta.payload.cwd"
      },
      "classification": [
        { "pattern": "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl", "category": "archivableSession" },
        { "pattern": "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl[.zst]", "category": "archivableSession" },
        { "pattern": "archived_sessions/rollout-<ISO>.jsonl.zst", "category": "archivableSession" },
        { "pattern": "config.toml", "category": "protected" },
        { "pattern": "config.toml.*", "category": "protected" },
        { "pattern": "auth.json", "category": "protected" },
        { "pattern": "prompts/**", "category": "protected" },
        { "pattern": "*.sqlite", "category": "protected" },
        { "pattern": ".tmp/**", "category": "cacheAndLog" }
      ],
      "selfCompressed": true,
      "sessionFileNaming": {
        "stableSessionIdentifier": false,
        "sessionIDSource": "fileName"
      }
    }
    """

    /// Cursor：主转录 + 同级子代理转录，一个会话跨多个文件。
    static let cursorJSON = """
    {
      "schemaVersion": 1,
      "id": "cursor",
      "displayName": "Cursor",
      "roots": [
        { "path": "~/.cursor", "role": "toolRoot" },
        { "path": "~/Library/Application Support/Cursor", "role": "displayOnly" }
      ],
      "structuralFingerprint": {
        "sessionFilePatterns": ["projects/<encodedPath>/agent-transcripts/<uuid>/<uuid>.jsonl"],
        "projectDirectoryShapes": ["projects/<encodedPath>/agent-transcripts"]
      },
      "cascade": [
        { "kind": "siblingTranscripts", "pattern": "subagents/*.jsonl" }
      ],
      "projectPathEncoding": {
        "scheme": "singleDash"
      },
      "classification": [
        { "pattern": "projects/<encodedPath>/agent-transcripts/<uuid>/<uuid>.jsonl", "category": "archivableSession" },
        { "pattern": "extensions/**", "category": "protected" },
        { "pattern": "mcp.json", "category": "protected" },
        { "pattern": "assets/**", "category": "uncertain" },
        { "pattern": "canvases/**", "category": "uncertain" }
      ],
      "selfCompressed": false,
      "sessionFileNaming": {
        "stableSessionIdentifier": true,
        "sessionIDSource": "fileName"
      }
    }
    """

    /// DeepSeek Harness：应用支持目录下自定义位置，自带 zstd 压缩，会话 ID 在父目录名里。
    static let harnessJSON = """
    {
      "schemaVersion": 1,
      "id": "deepseek-harness",
      "displayName": "DeepSeek Harness",
      "roots": [
        { "path": "~/Library/Application Support/deepseek-harness-desktop/harness-home", "role": "toolRoot" },
        { "path": "~/Library/Application Support/@deepseek-ai/dsh-desktop", "role": "displayOnly" }
      ],
      "structuralFingerprint": {
        "sessionFilePatterns": ["sessions/<encodedPath>/session-<uuid>/session.jsonl.zstd"],
        "sessionDirectoryShapes": ["sessions/<encodedPath>/session-<uuid>"]
      },
      "cascade": [],
      "projectPathEncoding": {
        "scheme": "doubleDash"
      },
      "classification": [
        { "pattern": "sessions/<encodedPath>/session-<uuid>/session.jsonl.zstd", "category": "archivableSession" },
        { "pattern": "settings.yaml", "category": "protected" },
        { "pattern": ".credentials.yaml", "category": "protected" },
        { "pattern": "storages/**", "category": "protected" },
        { "pattern": "profiles/**", "category": "protected" }
      ],
      "selfCompressed": true,
      "sessionFileNaming": {
        "stableSessionIdentifier": true,
        "sessionIDSource": "parentDirectoryName"
      }
    }
    """
}
