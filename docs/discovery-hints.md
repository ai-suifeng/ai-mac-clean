# 关键词 / 负向名单词表（v1）

**关键词不参与准入。** 结构指纹才是准入依据（GLOSSARY「结构指纹」，PRD §4.3、
spec #7 §发现管线）。这份词表只做两件事：

| 段 | 作用 | 能不能改变「是否进候选」 |
|---|---|---|
| `nameKeywords` | 给**已经进列**的候选排序；也是找同名 App / PATH 命令的匹配词 | **不能** |
| `negativeNamePatterns` | 把已进列的候选降权到「低」并标为「疑似」 | **不能**（只降权，不删除） |

一个名字里含 `claude` 却没有任何结构特征的目录，**根本不会出现在候选列表里**
（User Story 8、9，PRD A1）。词表因此永远拿不到「让噪声目录进候选」的能力。

## 格式

JSON。放在应用支持目录下，随版本一起更新；路径由调用方给出（`DiscoveryHints.load(from:)`），
本层不猜路径、不读 `NSHomeDirectory()`。

```jsonc
{
  "schemaVersion": 1,                       // 必填，必须等于当前支持版本
  "nameKeywords": {                         // 可选：工具标识 → 关键词
    "claude-code": ["claude", "anthropic"],
    "codex-cli": ["codex", "openai"],
    "cursor": ["cursor"]
  },
  "negativeNamePatterns": [                 // 可选：已知易误判的名字
    "*bak*",
    "*backup*",
    ".claude-*",
    ".codexbar",
    ".codexhost",
    ".antigravity_cockpit"
  ]
}
```

- 两个段都可以省略；省略后分别表示「不参与排序」与「没有负向名单」。
- 未知字段一律忽略，词表可以向前兼容。
- **词表错了要报错，不静默降级成空词表**：空词表不会让功能出错，只会让负向名单
  悄悄失效、旧快照悄悄变成高置信度候选——那正是本票要防的失败模式。

## 模式写法

单段内的通配符，`*` 匹配任意字符，**忽略大小写**；没有 `?`、没有字符类、不跨 `/`。
逐段比对路径的每一段，因此 `.claude-tap` 这类**带前导点**的名字要连点一起写。

写负向名单时**按实测名字写**，不要照抄记忆里的形态。实测里最容易踩的一条：

| 写法 | 能匹配 `~/.claudebak` 吗 |
|---|---|
| `*-bak` | ❌（它结尾是 `bak`，中间没有短横线） |
| `*.bak*` | ❌（它里面没有 `.bak`） |
| `*bak*` | ✅ |

PRD §4.3 列的是 `*-bak`、`*.bak*`、`*-backup*` 这一族形状，而实测存在的旧快照目录
是 `~/.claudebak`（798M）。因此默认词表里额外写了 `*bak*`；同理伴生小工具
（`~/.claude-tap`、`~/.codexbar`、`~/.codexhost`、`~/.antigravity_cockpit`）
应该逐个写全名，而不是靠 `claude*` 之类的粗放模式。

## 关键词之外还有一类证据

同名 App（`/Applications`、`~/Applications`）与 PATH 中的同名命令是**外部佐证**
（PRD §4.3「关联检测」）。它们由调用方采集后注入 `ExternalEvidence`，
关键词只用来在已采集到的名字里做匹配。本阶段**不发起任何网络请求**（User Story 45）。
