# 会话识别与级联（issue #26）

深扫（issue #23）回答「每个工具占了多少、其中多少可归档」；这一层回答
「这些可归档的文件分别属于**哪一个会话**」。GLOSSARY：会话 = 归档与还原的最小单位，
一个会话可能由主转录 + 子代理转录 + 关联数据多个文件组成。

- 入口：`SessionGrouper.group(tools:rules:homeDirectory:)`（协议 `SessionGrouping`）。
- 接缝：与深扫同一个可注入文件系统（`DiscoveryFileSystem`）与同一个受保护判定列举
  （`ProtectedPathDirectoryListing`），因此「碰了哪些路径」「有没有写过」可以用
  同一套记录器断言（`WriteRecordingDiscoveryFileSystem` / `AuditorFileSystem`）。
- 类别判定**复用**深扫那条链（`DeepScanRuleCatalog`）：可归档与否只有一处实现。

## 规则驱动，引擎里没有工具名分支

| 声明 | 决定什么 |
|---|---|
| `structuralFingerprint.sessionFilePatterns` | 哪些路径是**会话文件**（主转录） |
| `cascade[].kind` / `pattern` | 会话文件之外的关联文件怎么挂到会话上 |
| `sessionFileNaming.sessionIDSource` | 会话 ID 在**文件名**里还是**父目录名**里 |
| `sessionFileNaming.stableSessionIdentifier` | 文件名是不是稳定 ID（Codex 的 fork 不是） |
| `projectPathEncoding.scheme` / `fieldPath` | 项目名从哪来 |

新增一个已知工具因此只需要新增一个规则文件。

## 关联次序（一条路径只归一次）

1. **级联声明优先**：路径命中级联就按级联关联。Claude 的 `agent-<uuid>.jsonl`
   既在会话形状里、又在级联里，级联给出的角色更具体（子代理转录）。
2. 其次是**会话文件形状**：命中 `sessionFilePatterns` 就是主转录。
3. 都不是，但规则声明为可归档 → 进 `unmatched`（见下）。

级联的三种形态：

- `siblingTranscripts`：模式的基准是**主转录所在目录**。实现上从最深的祖先目录往上找
  第一个让剩余部分命中模式的目录，再看那个目录里有几份主转录。
- `sessionKeyedDirectory`：模式（`file-history/<uuid>`）命中的**祖先目录**给出会话 UUID，
  目录下的文件都随该会话。
- `sessionKeyedFile`：模式（`todos/<会话UUID>-agent-<另一个UUID>.json`）命中的文件，
  取**第一个** `<uuid>` 捕获作为会话 UUID——规则里的字段顺序就是语义顺序，
  且中间的字面量 `-agent-` 强制了边界。

## 会话 ID 的语义（这一层最要紧的选择）

`sessionIDSource: parentDirectoryName` 时，会话 ID **就是父目录名原样**
（Harness：`session-<uuid>/session.jsonl.zstd` → ID 为 `session-<uuid>`）。

`sessionIDSource: fileName` 时，取文件名主干里**第一个 UUID 形状的记号**
（`8-4-4-4-12` 个十六进制字符）：

- Claude `projects/<编码>/<uuid>.jsonl` → `<uuid>`；
- Cursor `agent-transcripts/<uuid>/<uuid>.jsonl` → 文件名的那个 `<uuid>`（规则声明的来源）；
- Codex `rollout-<ISO>-<uuid>.jsonl[.zst]` → `<uuid>`；
- Codex fork `rollout-<ISO>-<uuidA>_<uuidB>.jsonl[.zst]` → **`<uuidA>`（fork 链的根）**，
  于是 fork 出来的文件与它派生自的那份转录归到**同一个逻辑会话**（PRD §5.4）。

> 为什么不靠模式捕获切这两个 UUID：`<ISO>` 与 `<uuid>` 的字符集重叠
> （`PathPattern.captures` 里说明了这一点），哪种切法都能自圆其说；
> 按「文件名里第一个 UUID 形状记号」切只有一个答案。

文件名里没有 UUID 形状记号时（合成夹具里就有这种名字），退回**整个文件名主干**。
一个会话文件因此至少有一个稳定的 ID，绝不会因为「名字不规矩」而消失。

## 保守取值（文档没有规定的地方）

| 情况 | 取值 | 理由 |
|---|---|---|
| 同一目录下有多份主转录，还要挂 `agent-*.jsonl` | **不猜**：进 `unmatched`，列出候选 | 文件名里没有会话 UUID，硬挂会给出一个假的归属 |
| 关联数据找不到对应会话（转录已不在） | 进 `unmatched`，`sessionNotFound` | 如实呈现数据残缺，不并进别的会话 |
| 目录里只有子代理转录 | 进 `unmatched`，`noMainTranscript` | 同上 |
| 规则声明为可归档、却不符合任何会话形状 | 进 `unmatched`，`shapeNotDeclared` | 「不得静默丢弃」（issue #26 范围最后一条） |
| 规则没声明 `sessionFileNaming` | 按 `fileName` 处理 | 与四个内置工具一致的最常见形态 |
| `projectPathEncoding.scheme == inFileField`（Codex） | 只有字段路径、没有值 | 读文件内容不属于 M2（PRD §13 第 3 条），`.zst` 更不解码 |
| 同一会话 UUID 同时出现在 `sessions/` 与 `archived_sessions/` | 归并为一个会话 | 一个逻辑会话可能跨多个文件，存放位置不改变它是谁 |

**项目名一律原样展示**：`-Users-xiaowei--claude`、`--Users-x-a--` 这类编码目录名
绝不反向解码（PRD §5.3：解码有歧义）。

## 与深扫对账

每一层的可归档占用必须逐字节对得上：

```
会话内文件之和 + 未归组的可归档文件 = 深扫的「可归档会话」占用
```

这条不变量是 M3 按会话归档的前提（`SessionGroupingBundledRuleTests` 在出厂规则上钉住它）。
`unmatched` 里的文件**仍然算**这台工具的可归档占用——它们只是还没归好组，
不是「不用管」。

## 约定

- **零写入**：接口上只有读取，`.zst`/`.zstd` 只按扩展名识别、绝不试图解码。
- **不跟随符号链接**：链接进 `unfollowedLinks`，既不进会话，也不跟着它走。
- **权限错误按目录粒度隔离**：读不到的目录进 `unreadable`，不让一次归组整体失败。
- **规则声明的路径缺失是常态**（新版 `~/.claude` 没有 `file-history/`、`todos/`）：
  静默跳过，连列举都不发生（目录剪枝只走声明形状的字面前缀所在的子树）。
- 不在本层范围：归档（M3）、界面（#27/#28）、多根展示（#31）、zstd 解码（M6）。
