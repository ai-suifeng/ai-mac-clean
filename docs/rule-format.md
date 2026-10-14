# 规则文件格式（v1）

软件本体是通用引擎；**新增一个已知工具 = 新增一个规则文件**（spec #7 User Story 20）。
引擎里没有任何工具名分支，加载器也不认识 `~/.claude`、`~/.codex` 这些名字。

格式选 **JSON**：零第三方依赖是硬性约束（PRD §10），YAML 需要自带解析器；
JSON 还能直接进 `JSONDecoder`、输出确定（键排序），往返序列化可断言等价。

## 顶层结构

```jsonc
{
  "schemaVersion": 1,            // 必填，必须等于当前支持版本
  "id": "claude-code",           // 必填，稳定标识（小写短横线）
  "displayName": "Claude Code",  // 必填，界面展示名
  "roots": [                     // 必填，至少一条
    { "path": "~/.claude", "role": "toolRoot" }
  ],
  "structuralFingerprint": { ... },   // 可选
  "cascade": [ ... ],                  // 可选，默认 []
  "projectPathEncoding": { ... },      // 可选
  "classification": [ ... ],           // 可选，默认 []
  "selfCompressed": false,             // 可选，默认 false
  "sessionFileNaming": { ... }         // 可选
}
```

- 未知字段一律**忽略**，规则文件可以向前兼容。
- 省略的可选字段取保守默认值：不做任何分类声明、没有任何级联、不认为自带压缩。

## 路径写法

- `roots[].path`：以 `~/` 开头（相对 `$HOME`）或以 `/` 开头（绝对路径）。
- 其余所有 `pattern`：相对工具根目录、不以 `/` 开头的模式串。

### 路径模式语法

| 写法 | 含义 |
|---|---|
| `projects` | 字面分段 |
| `*` | 匹配单段内任意文本 |
| `**` | 递归匹配剩余分段；只能整段、且只能是最后一段 |
| `<uuid>` | 一段 UUID |
| `<uuid:标签>` | 带标签的 UUID（如 fork 文件名里的两个） |
| `<encodedPath>` | 项目路径编码后的目录名 |
| `<date:year>` / `<date:month>` / `<date:day>` | `sessions/YYYY/MM/DD` 的日期分量 |
| `<名字>` / `<name:名字>` | 其它具名占位段（如 `<ISO>`） |
| `[.zst]` | 可选字面量后缀 |

一个覆盖 PRD §5.4 全部实测形状的例子（Codex CLI）：

```jsonc
"structuralFingerprint": {
  "sessionFilePatterns": [
    "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl",
    "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl[.zst]",
    "archived_sessions/rollout-<ISO>.jsonl.zst"           // 扁平，无年月日嵌套
  ],
  "sessionDirectoryShapes": ["sessions/<date:year>", "archived_sessions"],
  "fileHeaderKeys": ["type", "payload"],
  "headerByteLimit": 8192                                  // 只读文件头若干字节
}
```

模式串会被解析成结构再保存；`canonicalString` 是**幂等**的规范写法
（`<uuidA>` 会规范成 `<uuid:A>`），因此「写入 → 读出 → 再序列化」结果等价。

## 文件级联

```jsonc
"cascade": [
  { "kind": "siblingTranscripts",   "pattern": "agent-<uuid>.jsonl" },
  { "kind": "sessionKeyedDirectory","pattern": "file-history/<name:sessionID>" },
  { "kind": "sessionKeyedFile",     "pattern": "todos/<name:sessionID>-agent-<name:sessionID>.json" }
]
```

`pattern` 的基准随 `kind` 而定：`siblingTranscripts` 相对主转录所在目录，
其余两种相对工具根目录。

## 项目路径编码

```jsonc
"projectPathEncoding": { "scheme": "doubleDash" }
"projectPathEncoding": { "scheme": "singleDash" }
"projectPathEncoding": { "scheme": "inFileField", "fieldPath": "session_meta.payload.cwd" }
```

引擎**不做逆向解码**：Claude Code 的编码不可无损逆解（`/Users/x/.claude` →
`-Users-xiaowei--claude`）。项目路径的权威来源只能是 `inFileField` 的 `fieldPath`，
其余方案下只能做存在性校验。`fieldPath` 只有 `inFileField` 允许出现。

## 分类与受保护路径

```jsonc
"classification": [
  { "pattern": "sessions/**/rollout-<ISO>.jsonl[.zst]", "category": "archivableSession" },
  { "pattern": "auth.json",                              "category": "protected" },
  { "pattern": "*.sqlite",                               "category": "uncertain" },
  { "pattern": ".tmp/**",                                "category": "cacheAndLog" }
]
```

类别是封闭枚举（PRD §5.1）：`archivableSession`（可归档会话）、`cacheAndLog`（缓存与日志）、
`protected`（受保护）、`uncertain`（不确定）。**受保护路径就是 `category: "protected"` 的条目**，
不另设字段。规则文件不能发明新类别，也不能把「不确定」降级为「可归档」——
这类判断属于规则集准入的保护单调性校验（issue #11），本层不实现。

## 自带压缩与会话文件名形态

```jsonc
"selfCompressed": true,                     // Codex 的 .zst、Harness 的 .zstd：不再重压缩（ADR-0001）
"sessionFileNaming": {
  "stableSessionIdentifier": false,         // fork 会话文件名含两个 UUID，不是稳定 ID
  "sessionIDSource": "fileName"             // 或 "parentDirectoryName"（Harness：ID 在父目录名）
}
```

## 加载器行为

- `RuleLoader.loadRule(at:)` / `loadRule(from:source:)`：单文件，失败抛 `RuleLoadError`。
- `RuleLoader.loadRules(inDirectory:)`：只读本层 `*.json`，一条坏规则变成一条 `RuleDiagnostic`，
  其余规则照常返回；目录不存在返回空结果。
- **不检查规则声明的路径在磁盘上是否存在**——路径缺失是扫描期「无匹配」，不是加载失败。
- 失败原因经 `errorDescription` 给出可读中文诊断，含文件名与出错字段。

实现见 `Sources/AIMacCleanRules/`。
