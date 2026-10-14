# 测试安全护栏（issue #14）

> 权威依据：spec #7「构造数据的纪律」第 1 条、PRD §13 第 3 条、PRD §10（测试）。
> 一句话：**测试禁止触碰真实 AI 工具数据目录，这件事由自动化保证，不靠自觉。**

## 三层防线

| 层 | 在哪 | 做什么 | 触发时 |
|---|---|---|---|
| 内核沙箱（拦截） | `Sources/AIMacCleanPathGuard` | 测试进程启动前（main 之前）给整个进程套上「真实目录一律不可读写」的内核沙箱规则 | 访问被内核拒绝（EPERM），测试当场失败；真实数据一个字节都没被读到 |
| Swift 断言（诊断） | `Tests/AIMacCleanTests/Support/ForbiddenRealToolDirectory.swift`、`RealToolDirectoryGuard.swift` | 被测代码每给出一条路径就断言一次，打印**违规路径 + 命中的禁区 + 来源** | `XCTFail`，失败信息带路径与来源 |
| 夹具守卫（前置） | `Tests/AIMacCleanTests/Support/TemporaryDirectoryFixture.swift` | 测试数据落地的唯一入口；落地前先判定 | 夹具创建直接抛错 |

三层都不读、不列、不 stat 那些真实目录：判定全部是**纯字符串运算**
（展开 `~/`、压重复斜杠、字面消解 `.`/`..`、大小写不敏感比较）。

## 怎么用

```bash
make test                      # 本地与 CI 同一条路径：自检护栏 + 跑测试
make test-guard-self-check     # 只验证「护栏真的会拦」
Scripts/run-tests.sh --demo-violation   # 跑违规演示（期望失败）
```

裸跑 `swift test` 同样受保护——护栏在测试可执行文件加载时就装上了。

## 扩充禁区清单

只改 `TestSupport/ForbiddenRealToolDirectories.txt` 一处，不用动任何代码。
C 内核层与 Swift 诊断层都从这一个文件读，不存在「改了这边忘了那边」的漂移。

## 为什么是内核沙箱，而不是拦截 libc 调用

最初想用 `DYLD_INSERT_LIBRARIES` 在 libc 层拦截每一个带路径的调用（`open`/`stat`/`opendir`/`unlink`…）。
**在本机 macOS 26.6 / dyld4 上实测不可行**，三种写法全部无效：

- `DYLD_INSERT_LIBRARIES` 注入的 dylib 能加载（构造器会跑），但**不会**重绑已加载客户端的符号；
- 在主可执行文件里直接定义 `stat`/`open`，只有自己进程内的调用走得到它，**Foundation 的调用不走**；
- Mach-O `__DATA,__interpose` 段同样不生效。

内核沙箱是唯一在用户态拿得到的、真·覆盖所有路径（含 Foundation、SwiftUI、系统命令）的机制，
且它按路径名判定，不需要枚举目录，因此不违反「不触碰」。

## fail closed

护栏装不上就**拒绝放行**，绝不「装不上也照样跑」：找不到清单、`sandbox_init` 不可用、
沙箱装载失败——任一情况都会打印明确原因并以退出码 70 结束。
`Scripts/run-tests.sh` 还会检查测试输出里的「护栏已装载」日志，缺失即判定这次绿灯不算数。

唯一的调试后门是 `AMC_TEST_GUARD_DISABLE=1`，它会在日志里明说自己已被关闭；
`make test` 与 CI 都不使用它。关掉它以后 `PathGuardSelfCheckTests` 会失败——这是故意的。

## 已知边界

- **不解析符号链接**：判定是字面的。`~/some-link -> ~/.claude` 这种间接指向拦不到入口那一跳，
  但内核沙箱仍然会在真正落到 `~/.claude` 时拒绝（子路径命中）。要在**第一次**访问就拦住符号链接指向，
  需要额外一层（对 `~` 本身做 deny），代价是禁止一切指向真实目录的软链；本阶段不采用。
- **fd 相对调用**：内核沙箱按最终路径判定，与调用形式无关；Swift 层的字面判定对
  `openat(dirfd, 相对名)` 这类 fd 相对操作不做判定（相对名的基准不可知），
  这类操作请先让被测代码给出绝对路径再断言。
- **`sandbox_init` 已被 Apple 标为废弃**（macOS 26 的 SDK 连头文件都移除了，本库自己声明符号并用
  `dlsym` 解析）。若将来系统真的拿掉它，护栏会明确拒绝放行而不是悄悄失效。
