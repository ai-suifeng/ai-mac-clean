# ai-mac-clean

AI 工具数据瘦身工具（见 [prd.md](prd.md) 与 spec #7）。

## 构建与测试

```bash
make build   # swift build
make test    # 自检路径护栏 + 跑全部测试（本地与 CI 同一条路径）
```

## 测试安全护栏（issue #14）

测试**禁止触碰真实的 AI 工具数据目录**（`~/.claude`、`~/.codex`、`~/.cursor` 等）。
这条规则由自动化强制执行，而不是靠自觉：

- 测试进程启动前即装载内核沙箱，从内核层面拒绝对这些目录的一切读写；
- 被测代码每给出一条路径，还有一层 Swift 断言会打印「违规路径 + 命中的禁区 + 来源」；
- 跑测试的入口（`make test` / CI）会先自检护栏确实会拦，再跑测试。

机制细节、扩充禁区清单的方法与已知边界见 [TestSupport/README.md](TestSupport/README.md)。
