# ai-mac-clean 本地入口。
#
# 测试一律走 `make test`：它跑的是带 issue #14 路径护栏的入口
# （Scripts/run-tests.sh），会先自检护栏真的会拦，再跑测试并确认护栏生效。
#
# 权威规则：spec #7「构造数据的纪律」第 1 条 / PRD §13 第 3 条 / PRD §10（测试）。

.PHONY: build test test-guard-self-check test-guard-violation-demo test-unguarded

build:
	swift build

## 受护栏保护的测试入口（本地与 CI 同一条路径）
test:
	./Scripts/run-tests.sh

## 只验证护栏真的会拦，不跑测试
test-guard-self-check:
	./Scripts/run-tests.sh --self-check-only

## 违规演示：故意触碰真实目录的测试必须被拦到整轮失败（期望「成功」= 护栏拦住了）
test-guard-violation-demo:
	./Scripts/run-tests.sh --demo-violation

## 后门：关掉护栏裸跑测试。仅用于调试护栏本身。
## 注意：PathGuardSelfCheckTests 会因此失败——这是故意的，要让「护栏没开」这件事吵起来。
test-unguarded:
	AMC_TEST_GUARD_DISABLE=1 swift test
