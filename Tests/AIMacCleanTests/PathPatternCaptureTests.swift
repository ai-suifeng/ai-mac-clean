import XCTest

@testable import AIMacCleanRules

/// Seam R2：路径模式的**逐段捕获**（issue #26 的会话归组要按规则声明的形状取项目名）。
///
/// 归组需要知道「这条路径落在规则声明的哪一段上」：`projects/<encodedPath>/<uuid>.jsonl`
/// 里的 `<encodedPath>` 就是会话所属项目的**编码目录名**（不可逆编码，只原样展示）。
/// 这件事只有模式自己说得清——模式知道自己的记号怎么切，外层的字符串切分只会重复一遍
/// 匹配语义并很快与 `matches` 走散。
///
/// 因此这里同时钉两条：捕获值取自**原文**（不因为比较是小写不敏感就丢掉大小写），
/// 以及「捕获得到的路径集合」与权威匹配 `matches` 完全一致（验收：两者不许各说各话）。
final class PathPatternCaptureTests: XCTestCase {

    // MARK: - Claude Code 的项目编码目录（验收 1、范围第 5 条）

    func test捕获ClaudeCode转录里的项目编码名与会话UUID() throws {
        let pattern = try PathPattern("projects/<encodedPath>/<uuid>.jsonl")
        let path = "projects/-Users-x-a/11111111-1111-1111-1111-111111111111.jsonl"

        let captures = try XCTUnwrap(pattern.captures(relativePath: path))
        XCTAssertEqual(captures.map(\.kind), [.encodedPath, .uuid])
        XCTAssertEqual(captures.map(\.value), ["-Users-x-a", "11111111-1111-1111-1111-111111111111"])
        XCTAssertEqual(captures.map(\.segmentIndex), [1, 2], "段序号指向模式里那一段，便于核对是第几段给出的")
        XCTAssertEqual(captures.map(\.label), [nil, nil])
    }

    /// 大小写不敏感只作用于**比较**：捕获值必须是磁盘上的原文，否则项目名会被改小写。
    func test捕获值保留原文大小写() throws {
        let pattern = try PathPattern("projects/<encodedPath>/<uuid>.jsonl")
        let captures = try XCTUnwrap(
            pattern.captures(relativePath: "projects/-Users-Xiaowei-Project/AbCdEf01-1111-1111-1111-111111111111.jsonl")
        )
        XCTAssertEqual(captures.map(\.value), ["-Users-Xiaowei-Project", "AbCdEf01-1111-1111-1111-111111111111"])
    }

    // MARK: - 与权威匹配一致

    func test不匹配的路径没有捕获() throws {
        let pattern = try PathPattern("projects/<encodedPath>/<uuid>.jsonl")
        XCTAssertNil(pattern.captures(relativePath: "projects/-Users-x-a/sessions-index.json"))
        XCTAssertNil(pattern.captures(relativePath: "projects/-Users-x-a"), "段数不够")
        XCTAssertNil(pattern.captures(relativePath: "projects/-Users-x-a/notes.txt"))
        XCTAssertFalse(pattern.matches(relativePath: "projects/-Users-x-a/sessions-index.json"))

        // `<uuid>` 的字符集是「十六进制 + 短横线」（issue #10 的宽松取值），
        // 因此 `1111.jsonl` 也算命中。宽松只会多命中、不会漏命中，这里如实钉住，
        // 免得日后有人以为捕获比匹配更严。
        XCTAssertEqual(pattern.captures(relativePath: "projects/-Users-x-a/1111.jsonl")?.last?.value, "1111")
        XCTAssertTrue(pattern.matches(relativePath: "projects/-Users-x-a/1111.jsonl"))
    }

    /// 捕获与匹配必须给出同一个「命中 / 不命中」答案。任一条路径上两者分家，
    /// 会话归组就会与分类统计对不上账。
    func test捕获与匹配在实测形状上完全一致() throws {
        let patterns = try [
            "projects/<encodedPath>/<uuid>.jsonl",
            "projects/<encodedPath>/agent-<uuid>.jsonl",
            "file-history/<uuid>/**",
            "todos/<uuid>-agent-<uuid>.json",
            "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl[.zst]",
            "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>-<uuidA>_<uuidB>.jsonl[.zst]",
            "archived_sessions/rollout-<ISO>.jsonl[.zst]",
            "projects/<encodedPath>/agent-transcripts/<uuid>/<uuid>.jsonl",
            "projects/<encodedPath>/agent-transcripts/<uuid>/subagents/*.jsonl",
            "sessions/<encodedPath>/session-<uuid>/session.jsonl.zstd",
        ].map { try PathPattern($0) }

        let paths = [
            "projects/-Users-x-a/11111111-1111-1111-1111-111111111111.jsonl",
            "projects/-Users-x-a/agent-a86b373.jsonl",
            "file-history/07e30f5f-7370-413d-a0eb-1b1fe4f604cb/9f2b@v1",
            "todos/07e30f5f-7370-413d-a0eb-1b1fe4f604cb-agent-07e30f5f-7370-413d-a0eb-1b1fe4f604cb.json",
            "sessions/2026/10/14/rollout-2026-10-14T09-08-28-0199f45a-e697-7243-a7fb-a441b54cb42e.jsonl.zst",
            "sessions/2026/10/14/rollout-2026-10-14T09-08-28-0199f45a-e697-7243-a7fb-a441b54cb42e.jsonl",
            "sessions/2026/10/14/rollout-2026-10-14T10-00-00-0199f45a-e697-7243-a7fb-a441b54cb42e_0199f45c-29dc-7fc1-9228-9662f09ed7b2.jsonl.zst",
            "archived_sessions/rollout-2026-10-13T00-00-00-0199f45a-e697-7243-a7fb-a441b54cb42e.jsonl.zst",
            "archived_sessions/rollout-2026-10-13T00-00-00.jsonl.zst",
            "projects/-Users-x-a/agent-transcripts/33333333-3333-3333-3333-333333333333/44444444-4444-4444-4444-444444444444.jsonl",
            "projects/-Users-x-a/agent-transcripts/33333333-3333-3333-3333-333333333333/subagents/55555555-5555-5555-5555-555555555555.jsonl",
            "sessions/--Users-x-a--/session-66666666-6666-6666-6666-666666666666/session.jsonl.zstd",
            "sessions/2026/10/14/rollout-2026-10-14T09-08-28-0199f45a.jsonl.zst",
            "claude-bak/projects/-Users-x-a/11111111-1111-1111-1111-111111111111.jsonl",
            "projects/-Users-x-a/notes.txt",
        ]

        for pattern in patterns {
            for path in paths {
                XCTAssertEqual(
                    pattern.captures(relativePath: path) != nil,
                    pattern.matches(relativePath: path),
                    "「\(pattern.canonicalString)」对「\(path)」的捕获与匹配不一致"
                )
            }
        }
    }

    // MARK: - 可选字面量与双 UUID（实测形状）

    func test捕获扁平已归档会话的ISO段() throws {
        let pattern = try PathPattern("archived_sessions/rollout-<ISO>.jsonl[.zst]")
        let captures = try XCTUnwrap(
            pattern.captures(relativePath: "archived_sessions/rollout-2026-10-13T00-00-00.jsonl.zst")
        )
        XCTAssertEqual(captures.map(\.value), ["2026-10-13T00-00-00"])
        XCTAssertEqual(captures.first?.label, "ISO")

        // 同一模式对明文形态同样给出捕获（`[.zst]` 是可选的）。
        let plain = try XCTUnwrap(
            pattern.captures(relativePath: "archived_sessions/rollout-2026-10-13T00-00-00.jsonl")
        )
        XCTAssertEqual(plain.map(\.value), ["2026-10-13T00-00-00"])
    }

    /// fork 文件名的 `<ISO>` 与 `<uuidA>` 字符集重叠（都是小写字母数字加 `-`/`_`），
    /// 于是「ISO 在哪结束、父 UUID 从哪开始」**没有唯一答案**——`<ISO>` 贪心地吃掉
    /// 最长合法前缀，`<uuidA>` 只剩最后一段。
    ///
    /// 这不是缺陷，而是一条边界：**会话归组因此不依赖捕获来切 UUID**。规则已经把
    /// 「文件名不是稳定 ID」声明在 `sessionFileNaming` 里，归组改用文件名里的
    /// 第一个 UUID 形状记号（父 UUID），那才是语义稳定的一刀。这里断言的是
    /// 捕获确实按贪心切、段数与标签不丢，避免它假装自己能切 UUID。
    func test捕获fork会话的双UUID文件名时按贪心切且不丢段() throws {
        let pattern = try PathPattern(
            "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>-<uuidA>_<uuidB>.jsonl[.zst]"
        )
        let captures = try XCTUnwrap(pattern.captures(
            relativePath: "sessions/2026/10/14/rollout-2026-10-14T10-00-00-0199f45a-e697-7243-a7fb-a441b54cb42e_0199f45c-29dc-7fc1-9228-9662f09ed7b2.jsonl.zst"
        ))
        XCTAssertEqual(captures.map(\.kind), [.date, .date, .date, .name, .uuid, .uuid])
        XCTAssertEqual(captures.map(\.label), ["year", "month", "day", "ISO", "A", "B"])
        XCTAssertEqual(captures.map(\.segmentIndex), [1, 2, 3, 4, 4, 4])
        XCTAssertEqual(captures.first(where: { $0.label == "ISO" })?.value,
                       "2026-10-14T10-00-00-0199f45a-e697-7243-a7fb",
                       "贪心：ISO 取最长合法前缀（这是捕获的边界，不是会话 ID 的依据）")
        XCTAssertEqual(captures.first(where: { $0.label == "A" })?.value, "a441b54cb42e")
        XCTAssertEqual(captures.first(where: { $0.label == "B" })?.value,
                       "0199f45c-29dc-7fc1-9228-9662f09ed7b2",
                       "fork UUID 仍是完整一段")
    }

    // MARK: - `**` 与占位段

    func test递归通配之后的段不再产出捕获() throws {
        let pattern = try PathPattern("file-history/<uuid>/**")
        let captures = try XCTUnwrap(
            pattern.captures(relativePath: "file-history/07e30f5f-7370-413d-a0eb-1b1fe4f604cb/9f2b@v1")
        )
        XCTAssertEqual(captures.map(\.value), ["07e30f5f-7370-413d-a0eb-1b1fe4f604cb"])
    }

    func test目录形状本身也能取出会话UUID() throws {
        let pattern = try PathPattern("file-history/<uuid>")
        let captures = try XCTUnwrap(
            pattern.captures(relativePath: "file-history/07e30f5f-7370-413d-a0eb-1b1fe4f604cb")
        )
        XCTAssertEqual(captures.map(\.value), ["07e30f5f-7370-413d-a0eb-1b1fe4f604cb"])
    }

    func test没有占位段时捕获为空数组而不是nil() throws {
        let pattern = try PathPattern("settings.json")
        XCTAssertEqual(pattern.captures(relativePath: "settings.json"), [])
        XCTAssertNil(pattern.captures(relativePath: "settings.local.json"))
    }
}
