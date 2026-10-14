/*
 * TestSupport/probe/guard-self-check.c —— issue #14 护栏验收探针
 *
 * 这个程序**故意**去访问一条落在真实 AI 工具数据目录下的路径，用来证明护栏真的会拦：
 *
 *   - 链上护栏（Scripts/run-tests.sh 的 guarded 变体）：内核沙箱把这次访问拒掉，
 *     探针拿到 EPERM，打印 GUARD-BLOCKED 并以 0 退出。
 *   - 不链护栏（unguarded 变体）：访问直达内核，打印 GUARD-ABSENT 并以 1 退出。
 *
 * 脚本同时跑这两个变体：只有「不链时确实能碰到、链上就碰不到」这一对结论成立，
 * 才说明护栏真的在起作用，而不是探针写错了。
 *
 * 安全：只用 stat() 拿目录元数据，不读内容、不枚举、不写任何文件。
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void)
{
    const char *home = getenv("HOME");
    if (home == NULL || home[0] == '\0') {
        fprintf(stderr, "GUARD-SETUP-FAILED: HOME 未设置\n");
        return 2;
    }

    char path[4096];
    snprintf(path, sizeof path, "%s/.claude", home);

    struct stat info;
    errno = 0;
    int result = stat(path, &info);

    if (result == 0) {
        printf("GUARD-ABSENT: stat(%s) 成功——护栏没有生效，测试真的能碰到真实数据目录\n", path);
        return 1;
    }
    if (errno == EPERM) {
        printf("GUARD-BLOCKED: stat(%s) 被内核沙箱拒绝（EPERM）——护栏生效\n", path);
        return 0;
    }

    /* 目标路径不存在时内核先回 ENOENT，这种情况下无法区分，只能算探针无效。 */
    printf("GUARD-INCONCLUSIVE: stat(%s) errno=%d，无法判定护栏状态\n", path, errno);
    return 2;
}
