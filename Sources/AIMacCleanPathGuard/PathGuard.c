/*
 * issue #14 测试安全护栏的内核层：装载沙箱 + 纯字面路径判定。
 *
 * 装载时机：构造器（__attribute__((constructor))）。本库随测试可执行文件静态链接，
 * 构造器在 main 之前、任何测试代码之前运行，所以「测试开始」与「护栏生效」之间没有缝隙。
 */

#include "include/AIMacCleanPathGuard.h"

#include <ctype.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define AMC_MAX_ROOTS 128

struct guard_root {
    char expanded[AMC_PATH_GUARD_MAX_PATH]; /* 展开+归一化后的绝对路径 */
    char folded[AMC_PATH_GUARD_MAX_PATH];   /* 同上，全部小写（macOS 默认大小写不敏感） */
    size_t folded_length;
};

static struct guard_root g_roots[AMC_MAX_ROOTS];
static size_t g_root_count = 0;
static bool g_armed = false;
static bool g_disabled = false;
static const char *g_home = "/";
static char g_log[1024] = {0};

/* macOS 26 的 SDK 已移除 <sandbox/sandbox.h>，但符号仍在 libsystem 里，
   所以这里自己声明并用 dlsym 解析——万一将来系统真的拿掉了，护栏会明确拒绝放行。 */
typedef int (*sandbox_init_fn)(const char *profile, uint32_t flags, char **error);

static void guard_log(const char *fmt, ...)
{
    char buffer[4096];
    va_list args;
    va_start(args, fmt);
    int len = vsnprintf(buffer, sizeof buffer, fmt, args);
    va_end(args);
    if (len > 0) {
        size_t size = (size_t)len < sizeof buffer ? (size_t)len : sizeof buffer - 1;
        fwrite(buffer, 1, size, stderr);
        fflush(stderr);
    }
}

/* 装不上护栏就不放行：宁可整轮测试起不来，也不允许「护栏没生效」。 */
static void guard_die(const char *reason) __attribute__((noreturn));

static void guard_die(const char *reason)
{
    guard_log("=== issue #14 测试安全护栏拒绝放行：%s ===\n", reason);
    _exit(70);
}

/* ------------------------------------------------------------ 路径归一化 */

/*
 * 把 path 变成比较用的绝对路径：展开前导 ~/、相对路径接工作目录、压掉重复斜杠、
 * 按字面消解 . 与 ..、去掉尾斜杠。纯字符串运算，不碰文件系统。
 */
static size_t guard_normalize(const char *path, char *out, size_t out_size)
{
    char joined[AMC_PATH_GUARD_MAX_PATH * 2];
    size_t length = 0;

    if (path == NULL || path[0] == '\0' || out_size == 0) {
        return 0;
    }

    if (path[0] == '~' && (path[1] == '/' || path[1] == '\0')) {
        length = (size_t)snprintf(joined, sizeof joined, "%s%s", g_home, path + 1);
    } else {
        length = (size_t)snprintf(joined, sizeof joined, "%s", path);
    }
    if (length >= sizeof joined) {
        length = sizeof joined - 1;
        joined[length] = '\0';
    }

    if (joined[0] != '/') {
        char with_cwd[AMC_PATH_GUARD_MAX_PATH * 2];
        char cwd[PATH_MAX];
        if (getcwd(cwd, sizeof cwd) == NULL) {
            return 0;
        }
        snprintf(with_cwd, sizeof with_cwd, "/%s/%s", cwd, joined);
        snprintf(joined, sizeof joined, "%s", with_cwd);
    }

    size_t out_length = 0;
    size_t stack[AMC_PATH_GUARD_MAX_PATH / 2][2];
    size_t depth = 0;
    const char *cursor = joined;

    out[out_length++] = '/';
    out[out_length] = '\0';

    while (*cursor != '\0') {
        while (*cursor == '/') {
            cursor++;
        }
        const char *segment = cursor;
        while (*cursor != '\0' && *cursor != '/') {
            cursor++;
        }
        size_t segment_length = (size_t)(cursor - segment);
        if (segment_length == 0) {
            continue;
        }
        if (segment_length == 1 && segment[0] == '.') {
            continue;
        }
        if (segment_length == 2 && segment[0] == '.' && segment[1] == '.') {
            if (depth > 0) {
                out_length = stack[--depth][0];
                out[out_length] = '\0';
            }
            /* 绝对路径上的前导 .. 无处可去，丢弃。 */
            continue;
        }
        if (out_length > 1) {
            out[out_length++] = '/';
        }
        if (out_length + segment_length + 1 >= out_size) {
            return 0;
        }
        stack[depth][0] = out_length;
        stack[depth][1] = segment_length;
        depth++;
        memcpy(out + out_length, segment, segment_length);
        out_length += segment_length;
        out[out_length] = '\0';
    }

    return out_length;
}

/* path 是否等于 root 或位于其之下（大小写不敏感）。 */
static bool guard_is_contained(const char *path, size_t path_length, const struct guard_root *root)
{
    if (path_length == root->folded_length) {
        return strncasecmp(path, root->folded, path_length) == 0;
    }
    return path_length > root->folded_length
        && strncasecmp(path, root->folded, root->folded_length) == 0
        && path[root->folded_length] == '/';
}

/* ------------------------------------------------------------ 清单装填 */

static const char *guard_find_list_file(void)
{
    const char *from_env = getenv("AMC_TEST_GUARD_LIST");
    if (from_env != NULL && from_env[0] != '\0') {
        return from_env;
    }

    /* 回退：从本库在可执行文件里的位置向上找仓库根的清单文件。
       .build/<triple>/debug/<pkg>PackageTests.xctest/Contents/MacOS/<bin> → 仓库根 */
    Dl_info info;
    if (dladdr((const void *)&guard_find_list_file, &info) != 0 && info.dli_fname != NULL) {
        char candidate[PATH_MAX];
        snprintf(candidate, sizeof candidate, "%s", info.dli_fname);
        for (int level = 0; level < 10; level++) {
            char probe[PATH_MAX];
            snprintf(probe, sizeof probe, "%s/TestSupport/ForbiddenRealToolDirectories.txt", candidate);
            if (access(probe, F_OK) == 0) {
                /* 命中后交给调用方：用一个静态缓冲保存路径。 */
                static char found[PATH_MAX];
                snprintf(found, sizeof found, "%s", probe);
                return found;
            }
            char *slash = strrchr(candidate, '/');
            if (slash == NULL) {
                break;
            }
            *slash = '\0';
        }
    }
    return NULL;
}

static void guard_load_roots(const char *list_path)
{
    FILE *stream = fopen(list_path, "r");
    if (stream == NULL) {
        guard_die("打不开禁区清单文件（AMC_TEST_GUARD_LIST 指定的路径读不了）");
    }

    char line[4096];
    while (fgets(line, sizeof line, stream) != NULL) {
        char *start = line;
        while (*start == ' ' || *start == '\t') {
            start++;
        }
        size_t length = strlen(start);
        while (length > 0 && (start[length - 1] == '\n' || start[length - 1] == '\r'
                              || start[length - 1] == ' ' || start[length - 1] == '\t')) {
            start[--length] = '\0';
        }
        if (length == 0 || start[0] == '#') {
            continue;
        }
        if (start[0] != '~' && start[0] != '/') {
            guard_die("禁区清单里有既非 ~/ 开头也非绝对路径的条目，拒绝放行");
        }
        if (g_root_count >= AMC_MAX_ROOTS) {
            guard_die("禁区清单条目过多");
        }

        struct guard_root *root = &g_roots[g_root_count];
        size_t expanded_length = guard_normalize(start, root->expanded, sizeof root->expanded);
        if (expanded_length == 0) {
            guard_die("禁区清单里有无法归一化的条目");
        }
        for (size_t i = 0; i < expanded_length; i++) {
            root->folded[i] = (char)tolower((unsigned char)root->expanded[i]);
        }
        root->folded[expanded_length] = '\0';
        root->folded_length = expanded_length;
        g_root_count++;
    }
    fclose(stream);

    if (g_root_count == 0) {
        guard_die("禁区清单是空的");
    }
}

/* ------------------------------------------------------------ 沙箱装载 */

static void guard_append_rule(char *profile, size_t size, const char *root)
{
    /* 转义路径里的引号与反斜杠，路径来自仓库清单但仍按不可信输入处理。 */
    size_t offset = strlen(profile);
    offset += (size_t)snprintf(profile + offset, size - offset, "(deny file-read* file-write* (subpath \"");
    for (const char *cursor = root; *cursor != '\0' && offset + 4 < size; cursor++) {
        if (*cursor == '"' || *cursor == '\\') {
            profile[offset++] = '\\';
        }
        profile[offset++] = *cursor;
    }
    snprintf(profile + offset, size - offset, "\"))");
}

static void guard_arm_sandbox(void)
{
    size_t capacity = (g_root_count + 2) * (AMC_PATH_GUARD_MAX_PATH + 64);
    char *profile = (char *)malloc(capacity);
    if (profile == NULL) {
        guard_die("分配沙箱规则失败");
    }

    strcpy(profile, "(version 1)(allow default)");
    for (size_t i = 0; i < g_root_count; i++) {
        guard_append_rule(profile, capacity, g_roots[i].expanded);
    }

    sandbox_init_fn init = (sandbox_init_fn)dlsym(RTLD_DEFAULT, "sandbox_init");
    if (init == NULL) {
        free(profile);
        guard_die("本机系统已不提供 sandbox_init，无法保证「测试不碰真实数据目录」");
    }

    char *error = NULL;
    int result = init(profile, 0, &error);
    if (result != 0) {
        char reason[512];
        snprintf(reason, sizeof reason, "内核沙箱装载失败：%s", error != NULL ? error : "未知原因");
        free(profile);
        guard_die(reason);
    }
    free(profile);

    snprintf(g_log, sizeof g_log,
             "issue #14 测试安全护栏已装载：内核沙箱生效，禁区 %zu 条（清单 %s）",
             g_root_count, getenv("AMC_TEST_GUARD_LIST") != NULL ? getenv("AMC_TEST_GUARD_LIST") : "仓库内 TestSupport/ForbiddenRealToolDirectories.txt");
    guard_log("%s\n", g_log);
}

/* 构造器：main 之前运行，此时任何测试代码都还没开始。 */
__attribute__((constructor)) static void amc_path_guard_install(void);

static void amc_path_guard_install(void)
{
    const char *disabled = getenv("AMC_TEST_GUARD_DISABLE");
    if (disabled != NULL && strcmp(disabled, "1") == 0) {
        /* 唯一的后门，且会在日志里明说。默认不用，CI 与入口脚本都不设。 */
        g_disabled = true;
        guard_log("issue #14 测试安全护栏已被 AMC_TEST_GUARD_DISABLE=1 关闭——本次运行不受保护\n");
        return;
    }

    g_home = getenv("HOME");
    if (g_home == NULL || g_home[0] == '\0') {
        struct passwd *entry = getpwuid(getuid());
        g_home = (entry != NULL && entry->pw_dir != NULL) ? entry->pw_dir : "/";
    }

    const char *list_path = guard_find_list_file();
    if (list_path == NULL) {
        guard_die("找不到禁区清单文件（设 AMC_TEST_GUARD_LIST 指向它）");
    }
    guard_load_roots(list_path);
    guard_arm_sandbox();

    g_armed = true;
}

/* ---------------------------------------------------------------- 公开 API */

bool amc_path_guard_is_armed(void)
{
    return g_armed;
}

const char *amc_path_guard_armed_log(void)
{
    return g_log;
}

const char *amc_path_guard_home(void)
{
    return g_home;
}

size_t amc_path_guard_root_count(void)
{
    return g_root_count;
}

int amc_path_guard_check_path(const char *path,
                              char *out_root,
                              size_t out_root_size,
                              char *out_path,
                              size_t out_path_size)
{
    if (out_root != NULL && out_root_size > 0) {
        out_root[0] = '\0';
    }
    if (out_path != NULL && out_path_size > 0) {
        out_path[0] = '\0';
    }
    if (path == NULL || path[0] == '\0') {
        return 0;
    }

    char normalized[AMC_PATH_GUARD_MAX_PATH];
    size_t length = guard_normalize(path, normalized, sizeof normalized);
    if (length == 0) {
        return 0;
    }
    if (out_path != NULL && out_path_size > 0) {
        snprintf(out_path, out_path_size, "%s", normalized);
    }

    for (size_t i = 0; i < g_root_count; i++) {
        if (guard_is_contained(normalized, length, &g_roots[i])) {
            if (out_root != NULL && out_root_size > 0) {
                snprintf(out_root, out_root_size, "%s", g_roots[i].expanded);
            }
            return 1;
        }
    }
    return 0;
}
