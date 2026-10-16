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
  "installations": [ ... ],            // 可选，默认 []：该工具已知的安装位置
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
- `installations[].path`：同一套写法（`~/…` 或绝对路径）。
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

## 安装路径声明（`installations`，issue #19）

```jsonc
"installations": [
  { "path": "/Applications/Cursor.app",      "kind": "appBundle" },
  { "path": "~/Applications/Cursor.app",     "kind": "appBundle" },
  { "path": "~/.claude/local/claude",        "kind": "executable" },
  { "path": "/opt/homebrew/bin/codex",       "kind": "executable" }
]
```

| 字段 | 取值 | 说明 |
|---|---|---|
| `path` | `~/…` 或绝对路径 | 该工具已知的安装位置 |
| `kind` | `appBundle` \| `executable` | `appBundle` 的路径必须以 `.app` 结尾 |

**语义：声明哪条，就只 `stat` 哪条。** 这是安装佐证的**唯一**来源：

- **不得列举通用位置，包括 `/Applications` 与 PATH**（`~/Applications` 同理），也不得列举主目录。
  一次发现对磁盘的访问只允许落在「规则声明的工具根内部」与「规则声明的安装路径本身」上
  （issue #19 验收 1）。
- 声明的路径不存在 = **没有安装佐证**，不是错误，更不是跳过该工具的理由。
- 省略 `installations` 表示「这个工具没有已知安装位置」：一条都不查。
  宁可停在「中」，也不替工具猜一个通用位置（issue #19：不为了凑置信度编路径）。
- 安装佐证只影响「高 / 中」分档与同档排序，**不是准入门**：工具卸载了、数据还在磁盘上，
  候选照样出现，只是拿不到安装佐证、停在「中」（PRD §4.3、issue #18 的口径，不回退）。

写内置规则时只写**确有其事**的路径；不确定就不写。

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
  { "pattern": "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl[.zst]", "category": "archivableSession" },
  { "pattern": "auth.json",                              "category": "protected" },
  { "pattern": "*.sqlite",                               "category": "uncertain" },
  { "pattern": ".tmp/**",                                "category": "cacheAndLog" }
]
```

类别是封闭枚举（PRD §5.1）：`archivableSession`（可归档会话）、`cacheAndLog`（缓存与日志）、
`protected`（受保护）、`uncertain`（不确定）。**受保护路径就是 `category: "protected"` 的条目**，
不另设字段。规则文件不能发明新类别，也不能把「不确定」降级为「可归档」——
这类判断属于规则集准入的保护单调性校验（issue #11），本层不实现。

### 分类判定顺序（issue #25 验收 6）

一条路径同时命中多条分类条目时，归属到**判定顺序**最高的那一类，与条目写在 JSON 里的
先后无关：

| 顺序 | 类别 | 为什么排在这里 |
|---|---|---|
| 1 | `protected`（受保护） | 永不触碰；同时是代码层强制的不变量（PRD §8.1），任何宽泛声明都不能盖过它 |
| 2 | `uncertain`（不确定） | 「认不出来，仅展示占用」比「这是缓存」更保守——后者可能被读成「可以清」（PRD §2.3） |
| 3 | `cacheAndLog`（缓存与日志） | 仅展示占用，不动 |
| 4 | `archivableSession`（可归档会话） | 最低档：没有任何更高档承诺时才成立 |

**没有命中任何条目 = 不确定**（`ClassificationResolution.unclassified`）：规则没声明过的数据
就是「无法安全分类」的数据（PRD §5.1）。四类占用不能留下第五类「未分类」，而这个默认值
也只有一个方向——**绝不默认成可归档**。

判定顺序是引擎行为（`Sources/AIMacCleanRules/ClassificationResolution.swift`），
规则文件不用、也无法改写它；调整条目顺序不会改变任何一条路径的归属。

「受保护」这一档有两个来源，合起来才是 PRD §8.1 的下界：

- 规则里的 `category: "protected"` 条目；
- **代码层的内置受保护清单**（`BuiltInProtectedPaths`）。它的文件条目按**最后一段**判定，
  因此 `.credentials.json`、`state.sqlite` 这类嵌套文件也受保护——规则模式是「整条相对路径」，
  单段模式表达不了嵌套层级，这一段只能靠内置清单兜住（PRD §8.3）。

深扫取类别时把内置清单判一次、作为最高档传进来：

```swift
report.category(forRelativePath: path, ruleID: id, isBuiltInProtected: isProtected)
```

传 `true` 时结论一定是 `protected`，规则把它声明成什么都不改变结论；这份判定要列举
规则声明的工具根（符号链接真实目标），因此**算一次、复用**，不要每个文件都列举一遍。

### 分类模式相对哪个根（issue #25）

`classification[].pattern` 相对**包含该路径的那个已声明根**匹配，因此一条模式可以同时
作用于 `toolRoot` 与 `displayOnly` 根。`displayOnly` 根（Cursor AppSupport、Harness 的
纯 Electron profile）不参与准入与结构指纹，但它的数据同样要出现在占用里，所以照样需要
分类声明：实测的大头写具体模式（`User/**` 归不确定、`Cache/**` 归缓存与日志），
其余未声明的按上面的默认落在不确定档。

**不得用兜底 `**`**：`{ "pattern": "**", "category": … }` 会把受保护区一起吞掉，
出厂规则里一条都没有（`BundledToolRuleTests.test内置规则的分类声明没有兜底通配`）。

### 深扫怎么用这些根（issue #31）

- **一个工具的所有已声明根都进占用**：深扫自己从规则里取该工具的根（主根 + `displayOnly` 根），
  不要求调用方逐个传；`~/…` 用调用方给的主目录展开。`DeepScanReport` 的
  `ToolScanReport.roots` 按根分列占用，概览页据此显示「Cursor 2.1G + 14G 只展示」（PRD §14.1）。
- **`displayOnly` 根内的路径一律不可归档**：按规则声明落在缓存与日志 / 受保护 / 不确定三类之一，
  未声明的落进不确定；规则若在其上声明了 `archivableSession`，深扫把它压回不确定
  （PRD §2.3、§5.4：只展示、绝不动）。
- **缺失的 `displayOnly` 根静默跳过**：不报错、不进「读不到」清单，也不算这个工具占用的贡献者
  （PRD §5.4「规则容忍缺失」）。
- **文件形态的根**照样进占用，但分类只可能来自内置受保护清单或不确定
  ——规则的模式都相对**根**匹配，某个路径相对它就是它自己，谁也匹配不到它。
  出厂规则里就有这样一条：claude-code 把 `~/.claude.json` 声明成 `displayOnly` 根，
  它的字节因此出现在 Claude Code 的占用里（受保护，内置条目 `home/claude-state`），
  但一个字节都不算可归档。以前只声明 `~/.claude`，这个文件从来没进过任何工具的占用
  （`DeepScanBundledRuleTests.test出厂规则把主目录的claude状态文件作为文件形态的仅展示根计入占用`）。

## 自带压缩与会话文件名形态

```jsonc
"selfCompressed": true,                     // Codex 的 .zst、Harness 的 .zstd：不再重压缩（ADR-0001）
"sessionFileNaming": {
  "stableSessionIdentifier": false,         // fork 会话文件名含两个 UUID，不是稳定 ID
  "sessionIDSource": "fileName"             // 或 "parentDirectoryName"（Harness：ID 在父目录名）
}
```

## 规则集准入（Seam 2）

加载器只管「读得进来」，准入（`RuleSetAdmission`）管「能不能用」。入口有两个：

```swift
RuleSetAdmission.admit(rules: [ToolRule], homeDirectory: String) -> RuleAdmissionReport
RuleSetAdmission.admit(rawRules: [RawToolRule], homeDirectory: String) -> RuleAdmissionReport
```

`homeDirectory` 由调用方显式传入，本层不读 `NSHomeDirectory()`。

结果同时表达两件事：

| 成员 | 含义 |
|---|---|
| `usableRules` | 已验证可用的规则集（被拒绝的规则整体不在里面） |
| `rejections` | 被拒绝的规则，一条一个原因，原因文本可直接展示 |

单条规则的判定也可以直接打，不必先凑一批：

```swift
RuleSetAdmission.rejection(forRule: rule, homeDirectory: home)   // RuleRejection?
```

### 拒绝规则的三种情形

1. **保护单调性**（`RuleRejectionReason.protectionMonotonicity`）：某条分类条目声明的模式
   **整片**落在内置受保护区域内，且类别**不是** `protected`。内置受保护路径是下界，
   用户规则只能声明为受保护，不能改判成别的类别（PRD §8.1、spec #7「规则集准入」、
   验收 A16、User Story 29）。
2. **不确定降级**（`uncertainDowngrade`）：模式整片落在 PRD §5.1 点名的「不确定」形态里
   （`*.sqlite*`、`*.pb`、`IndexedDB*`、`leveldb*`、`*.blob*`），却声明成 `archivableSession`。
   不确定数据无法安全分类，只能仅展示占用。
3. **类别封闭**（`malformed`）：凭空发明新类别，或规则读不进来。

判为 `cacheAndLog` / `uncertain` **同样拒绝**。这两个类别虽然也不动数据，但各自带着一句
用户会读到的承诺——「这是缓存，可以清」「这个认不出来，只能放着」。内置清单说这条路径受保护，
规则却给出另一句承诺，界面就会同时显示两个互相矛盾的标签。因此正确写法只有一个：改成
`protected`。`Sources/AIMacCleanRules/BundledRules/*.json` 里凡是撞上内置清单的路径
（Claude 的 `shell-snapshots/**`、Codex 的 `*.sqlite*`）都按这条办理，出厂规则零拒绝。

被拒绝的整条规则都不在 `usableRules` 里——包括它自己声明为受保护的那些条目。

### 写规则时的几条纪律

- **判定看的是「整片是否落在受保护区域内」**。`auth.json`、`config.toml`、
  `settings.json` 这类指名道姓的写法一定会被拒绝；`logs/**` 这类宽泛写法只是写得粗糙，
  不会被拒绝——因为真正兜底的是代码层的内置保护（PRD §8.3：命中受保护规则的路径即使被
  规则或用户选中，也直接拒绝归档与移除）。想让「误伤面」变小，就把模式写具体。
- **占位符按实际取值范围收紧**：`<uuid>` 只可能是十六进制与短横线，`<date:…>` 只可能是数字，
  `<encodedPath>` / `<名字>` 是**不含点**的单段标识符。因此
  `projects/<encodedPath>/<uuid>.jsonl` 不会被内置条目 `claude-code/history` 误伤。
- **工具根按符号链接的真实目标判定（准入这一层）**：`~/.codex/skills` → `~/.agents/skills`
  形态下，链接覆盖的整片区域都算受保护区域，规则不能把它改判成别的类别（PRD §14.5）。
  到了**深扫 / 占用**这一层则一律**不跟随链接**：链接仍被判定为受保护
  （`UnfollowedLink.protectionReason`，界面据此说「这里有一份碰不得的技能」），
  但目标一个字节都不进这台工具的占用，也不被遍历——否则 `~/.agents/skills` 会被同时
  算进 `~/.codex` 与 `~/.opencode`，概览总数对不上 `du`（spec #22、issue #23 验收 4）。
- **规则容忍缺失**：声明的路径在磁盘上不存在不是拒绝理由（User Story 22），
  准入判定完全走路径形状、不 stat 磁盘。
- **拒绝粒度是单条规则**：一条坏规则不会让其余已知工具的规则失效，
  但它整体（包括它自己声明为受保护的条目）都不会进入可用规则集。

## 内置规则资源（issue #15）

内置规则是**真实的规则文件**，随包分发，不是源码里的字符串：

```
Sources/AIMacCleanRules/BundledRules/*.json     ← 规则文件本体
Sources/AIMacCleanRules/BuiltInRuleResources.swift ← 只给出这个目录在 bundle 里的位置
```

`Package.swift` 用 `resources: [.copy("BundledRules")]` 把它打进资源 bundle，
`BuiltInRuleResources.directory` 经 `Bundle.module` 解析。
**新增一个已知工具 = 在该目录放一个 JSON 文件**，引擎、加载器、准入都不需要改动，
因此加载器里也永远不会出现工具名分支。

一个目录下的 `*.json` 一条规则（`RuleLoader.loadRules(inDirectory:)` 只读本层）。
文件名约定 `<id>.json`（`id` 即工具标识），但加载器不依赖这个约定。

### 内置规则一览

| 规则文件 | 工具根 | 安装路径声明 | 项目路径编码 | 自带压缩 | 覆盖深度 |
|---|---|---|---|---|---|
| `claude-code.json` | `~/.claude` | `~/.claude/local/claude`、`~/.local/bin/claude` | `singleDash` | 否 | 实测校正（PRD §5.4 / §14.5） |
| `codex-cli.json` | `~/.codex` | `/opt/homebrew/bin/codex`、`/usr/local/bin/codex` | `inFileField`（`session_meta.payload.cwd`） | 是（`.zst`） | 实测校正 |
| `cursor.json` | `~/.cursor` | `/Applications/Cursor.app`、`~/Applications/Cursor.app` | `singleDash` | 否 | 会话形态待 M6；只展示位置已按实测归位（issue #25） |
| `deepseek-harness.json` | `…/deepseek-harness-desktop/harness-home` | `/Applications/DeepSeek Harness.app` | `doubleDash` | 是（`.zstd`） | 会话形态待 M6；纯 Electron profile 已按实测归位（issue #25） |
| `opencode.json` | `~/.local/share/opencode` | **不声明**（没有确有其事的路径） | 不声明 | 否 | 仅发现（User Story 7） |

写这些规则时用掉的几条纪律：

- **安装路径只写确有其事的**：`opencode.json` 一条都不声明，因此 OpenCode 拿不到安装佐证、
  停在「中」——这是正确的保守取值，不是遗漏。**宁可没有佐证，也不编一条路径出来。**
- **版本差异靠「容忍缺失」表达，不靠两套规则**：新版 Claude Code 没有
  `file-history/`、`todos/`、`statsig/`（文件历史已内联进转录），旧版才有。
  规则把它们声明成会话级联的关联数据即可——加载与准入都不 stat 磁盘，
  路径不存在是扫描期「无匹配」（User Story 22/23）。
- **会话目录形状用 `<uuid>`**：Codex 的 fork 文件名含两个 UUID，写成
  `rollout-<ISO>-<uuid:parent>_<uuid:fork>.jsonl[.zst]` 才表达得出「一个逻辑会话跨多个文件」。
- **标签要与内置保护清单一致**：内置清单列为受保护的条目（`shell-snapshots/`、
  `*.sqlite*`），规则里就声明 `protected`，而不是标成 `cacheAndLog`——后者不拒绝，
  但会产出一条「它其实仍受保护」的警告，让界面去解释一件本可以避免的事。
- **`classification` 模式要窄**：不带兜底的 `**`。「写宽了」不会被拒绝，
  但会让误伤面变大（PRD §8.3：真正的兜底在代码层的内置保护）。
- **只展示的数据也要有类别**：`displayOnly` 根不参与准入，但它的内容必须落在
  受保护 / 不确定 / 缓存与日志里——确认过的大头写具体模式（Cursor AppSupport 的
  `User/**`、`Cache/**`），其余走「未命中 = 不确定」的默认值，而不是漏成没声明（issue #25）。
- **判定顺序不用写进规则**：同一路径命中多条时由 `ClassificationResolution` 按
  「受保护 > 不确定 > 缓存与日志 > 可归档会话」归属，条目顺序随意（issue #25 验收 6）。
- **文档没说的就取保守值**：OpenCode 的项目路径在 `session.directory` **数据库列**里，
  PRD §5.3 写明第一期不做，而格式里没有「数据库列」这一档，因此**不声明编码方案**，
  而不是硬塞一个 `inFileField` 让引擎去读文件头。

## 加载器行为

- `RuleLoader.loadRule(at:)` / `loadRule(from:source:)`：单文件，失败抛 `RuleLoadError`。
- `RuleLoader.loadRules(inDirectory:)`：只读本层 `*.json`，一条坏规则变成一条 `RuleDiagnostic`，
  其余规则照常返回；目录不存在返回空结果。
- **不检查规则声明的路径在磁盘上是否存在**——路径缺失是扫描期「无匹配」，不是加载失败。
- 失败原因经 `errorDescription` 给出可读中文诊断，含文件名与出错字段。

实现见 `Sources/AIMacCleanRules/`。
