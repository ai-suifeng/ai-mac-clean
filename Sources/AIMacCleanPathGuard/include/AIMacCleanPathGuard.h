/*
 * AIMacCleanPathGuard —— issue #14「测试禁止触碰真实 AI 工具数据目录」的可复用护栏内核。
 *
 * 权威依据：spec #7「构造数据的纪律」第 1 条、PRD §13 第 3 条、PRD §10（测试）。
 *
 * 三层防线里最底的那一层在这里：**内核沙箱**。本动态库随测试可执行文件一起加载，
 * 在任何测试代码运行之前就给整个进程套上「这些真实目录一律不可读写」的沙箱规则。
 * 于是无论被测代码经由哪条路径（Foundation、SwiftUI、libc、系统命令）去碰这些目录，
 * 内核都会拒绝，测试当场失败，而真实数据一个字节都不会被读到或写坏。
 *
 * 本库还提供一层**纯字面判定**（不 stat、不列目录、不读文件），供测试在发现路径时
 * 给出「哪条路径、命中哪个禁区、来自哪里」的精确诊断——那正是 spec 要求打印的东西。
 *
 * 约束：
 *   - 零第三方依赖，只用系统头文件；部署目标 macOS 13+。
 *   - 清单文件是唯一来源：C 层与 Swift 层都读 TestSupport/ForbiddenRealToolDirectories.txt。
 *   - 装不上就拒绝放行：找不到清单、sandbox_init 不可用或失败，都直接以非零码退出，
 *     绝不「护栏失效也照样跑测试」。
 */

#ifndef AIMACCLEAN_PATH_GUARD_H
#define AIMACCLEAN_PATH_GUARD_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AMC_PATH_GUARD_MAX_PATH 4096

/// 护栏是否已装载（内核沙箱已对本进程生效）。
bool amc_path_guard_is_armed(void);

/// 装载时写到 stderr 的一行日志，形如
/// `issue #14 测试安全护栏已装载：内核沙箱生效，禁区 8 条（清单 …）`。
/// 测试入口脚本与 CI 用它在护栏没生效时立刻失败（fail closed）。
const char *amc_path_guard_armed_log(void);

/// 用户主目录；清单里 `~/` 展开的锚点。
const char *amc_path_guard_home(void);

/// 纯字面判定：path 是否落在禁区目录之下。
///
/// 全程字符串运算：不 stat、不列目录、不读文件、不解析符号链接——护栏自己
/// 绝不触碰真实 AI 工具数据目录。
///
/// 命中时把命中的禁区根（绝对路径）写进 out_root 并返回 1，否则返回 0。
/// path_out 用于回写归一化后的绝对路径（可为 NULL）。
int amc_path_guard_check_path(const char *path,
                              char *out_root,
                              size_t out_root_size,
                              char *out_path,
                              size_t out_path_size);

/// 禁区条目数量。
size_t amc_path_guard_root_count(void);

#ifdef __cplusplus
}
#endif

#endif /* AIMACCLEAN_PATH_GUARD_H */
