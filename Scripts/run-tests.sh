#!/usr/bin/env bash
#
# issue #14：本地与 CI 共用的**受护栏保护**的测试入口。
#
# 做两件事，缺一不可：
#   1. 护栏验收自检——先证明护栏真的会拦（不链护栏时探针能碰到真实目录，链上就碰不到）；
#      自检不过就直接失败，绝不带着失效的护栏继续跑。
#   2. 跑完整测试套件，并确认这轮测试**确实是在护栏生效的状态下**跑的
#      （检查装载日志，缺失即失败——护栏没生效的绿灯没有任何意义）。
#
# 护栏本身在测试进程启动时（main 之前）由 Sources/AIMacCleanPathGuard 装载内核沙箱，
# 所以 `swift test` 本身也是受保护的；本脚本负责的是「证明它生效」并把结论留在日志里。
#
# 用法：
#   Scripts/run-tests.sh                 # 自检 + 全量测试
#   Scripts/run-tests.sh --filter Foo    # 透传 swift test 的参数
#   Scripts/run-tests.sh --self-check-only   # 只跑护栏自检，不跑测试
#   Scripts/run-tests.sh --demo-violation     # 只跑违规演示，并**期望**它失败

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST_FILE="$REPO_ROOT/TestSupport/ForbiddenRealToolDirectories.txt"
GUARD_SOURCE="$REPO_ROOT/Sources/AIMacCleanPathGuard/PathGuard.c"
PROBE_SOURCE="$REPO_ROOT/TestSupport/probe/guard-self-check.c"
BUILD_DIR="$REPO_ROOT/.build/pathguard"

export AMC_TEST_GUARD_LIST="$LIST_FILE"

fail() {
    echo "✗ $*" >&2
    exit 1
}

# --- 1. 护栏验收自检 -------------------------------------------------------

run_self_check() {
    [ -f "$LIST_FILE" ] || fail "找不到禁区清单：$LIST_FILE"
    mkdir -p "$BUILD_DIR"

    # 变体 A：不链护栏。必须能碰到真实目录——否则说明探针本身写错了，
    # 「被拦住」就不能作为护栏生效的证据。
    clang -mmacosx-version-min=13.0 -o "$BUILD_DIR/probe-unguarded" "$PROBE_SOURCE"
    local unguarded_output
    unguarded_output="$("$BUILD_DIR/probe-unguarded" 2>/dev/null || true)"
    case "$unguarded_output" in
        *GUARD-ABSENT*) echo "✓ 自检：无护栏时探针能碰到真实数据目录（对照组成立）" ;;
        *) echo "$unguarded_output"; fail "自检失败：不链护栏时探针没能碰到真实数据目录，对照组不成立" ;;
    esac

    # 变体 B：链上护栏。必须被内核拒绝。
    clang -mmacosx-version-min=13.0 -o "$BUILD_DIR/probe-guarded" "$PROBE_SOURCE" "$GUARD_SOURCE"
    local guarded_output
    guarded_output="$("$BUILD_DIR/probe-guarded" 2>/dev/null || true)"
    case "$guarded_output" in
        *GUARD-BLOCKED*) echo "✓ 自检：链上护栏后探针被内核拒绝（EPERM）——护栏真的在拦" ;;
        *) echo "$guarded_output"; fail "自检失败：链上护栏后探针仍然碰到了真实数据目录" ;;
    esac
}

# --- 违规演示：故意去碰真实目录的测试，必须被护栏拦到整轮失败 ----------------

run_violation_demo() {
    [ -f "$LIST_FILE" ] || fail "找不到禁区清单：$LIST_FILE"

    local log="$BUILD_DIR/violation-demo.log"
    set +e
    AMC_TEST_GUARD_DEMO=1 swift test --filter PathGuardViolationDemoTests >"$log" 2>&1
    local status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        cat "$log"
        fail "违规演示用例通过了——说明护栏没有拦住对真实目录的访问"
    fi
    if ! grep -q "护栏没有拦住" "$log"; then
        cat "$log"
        fail "违规演示不是被护栏拦下的（输出里没有护栏判定的失败信息）"
    fi

    echo "✓ 违规演示：故意触碰真实目录的测试确实失败，护栏拦住了（这是期望的结果）"
}

case "${1:-}" in
    --self-check-only)
        run_self_check
        exit 0
        ;;
    --demo-violation)
        run_self_check
        run_violation_demo
        exit 0
        ;;
esac

run_self_check

# --- 2. 跑测试并确认护栏生效 -----------------------------------------------

LOG_FILE="$BUILD_DIR/swift-test.log"

echo "▸ 运行测试（护栏已装载，清单 ${LIST_FILE}）"
set +e
swift test "$@" 2>&1 | tee "$LOG_FILE"
TEST_STATUS="${PIPESTATUS[0]}"
set -e

# 无论测试本身过没过，都要先确认这一轮是在护栏生效的状态下跑的。
if ! grep -q "护栏已装载" "$LOG_FILE"; then
    fail "这一轮测试没有护栏装载日志——护栏没生效，这次绿灯不算数"
fi

if [ "$TEST_STATUS" -ne 0 ]; then
    fail "测试失败（退出码 $TEST_STATUS）"
fi

echo "✓ 测试通过，且确认在 issue #14 护栏生效下运行"
