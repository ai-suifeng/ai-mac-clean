import XCTest

@testable import AIMacCleanRules

/// Seam R1：路径模式（issue #10 的验收「四套实测形状都要能表达」）。
///
/// 断言的是公开接口 `PathPattern` 的行为：写出来的模式串能被解析成结构，
/// 再序列化回规范形式。匹配语义属于 issue #5（指纹匹配与打分），这里不碰。
final class PathPatternTests: XCTestCase {

    // MARK: 实测形状（PRD §5.4）

    func test解析ClaudeCode的项目编码转录模式() {
        let pattern = try! PathPattern("projects/<encodedPath>/<uuid>.jsonl")
        XCTAssertEqual(pattern.segments.count, 3)
        XCTAssertEqual(pattern.segments[1].tokens, [.placeholder(kind: .encodedPath, label: nil)])
        XCTAssertEqual(pattern.segments[2].tokens, [.placeholder(kind: .uuid, label: nil), .literal(".jsonl")])
    }

    func test解析Codex的年月日嵌套模式() {
        let pattern = try! PathPattern("sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl")
        XCTAssertEqual(pattern.segments.count, 5)
        XCTAssertEqual(pattern.segments[1].tokens, [.placeholder(kind: .date, label: "year")])
        XCTAssertEqual(pattern.segments[3].tokens, [.placeholder(kind: .date, label: "day")])
        XCTAssertEqual(pattern.segments[4].tokens, [.literal("rollout-"), .placeholder(kind: .name, label: "ISO"), .literal(".jsonl")])
    }

    func test解析扁平已归档会话模式() {
        let pattern = try! PathPattern("archived_sessions/rollout-<ISO>.jsonl.zst")
        XCTAssertEqual(pattern.segments.count, 2)
        XCTAssertEqual(pattern.segments[0].tokens, [.literal("archived_sessions")])
        XCTAssertEqual(pattern.segments[1].tokens, [.literal("rollout-"), .placeholder(kind: .name, label: "ISO"), .literal(".jsonl.zst")])
    }

    func test解析fork会话的双UUID文件名() {
        let pattern = try! PathPattern("sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>-<uuidA>_<uuidB>.jsonl[.zst]")
        let leaf = pattern.segments[4]
        XCTAssertEqual(leaf.tokens, [
            .literal("rollout-"),
            .placeholder(kind: .name, label: "ISO"),
            .literal("-"),
            .placeholder(kind: .uuid, label: "A"),
            .literal("_"),
            .placeholder(kind: .uuid, label: "B"),
            .literal(".jsonl"),
            .optionalLiteral(".zst"),
        ])
    }

    func test解析Cursor的主转录与子代理转录() {
        let main = try! PathPattern("projects/<encodedPath>/agent-transcripts/<uuid>/<uuid>.jsonl")
        XCTAssertEqual(main.segments.count, 5)
        XCTAssertEqual(main.segments[2].tokens, [.literal("agent-transcripts")])

        let subagent = try! PathPattern("projects/<encodedPath>/subagents/*.jsonl")
        XCTAssertEqual(subagent.segments[3].tokens, [.wildcard, .literal(".jsonl")])
    }

    func test解析Harness的单文件会话模式() {
        let pattern = try! PathPattern("sessions/<encodedPath>/session-<uuid>/session.jsonl.zstd")
        XCTAssertEqual(pattern.segments.count, 4)
        XCTAssertEqual(pattern.segments[2].tokens, [.literal("session-"), .placeholder(kind: .uuid, label: nil)])
        XCTAssertEqual(pattern.segments[3].tokens, [.literal("session.jsonl.zstd")])
    }

    // MARK: 往返

    func test模式串往返后等价() {
        let sources = [
            "projects/<encodedPath>/<uuid>.jsonl",
            "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl",
            "archived_sessions/rollout-<ISO>.jsonl.zst",
            "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>-<uuidA>_<uuidB>.jsonl[.zst]",
            "projects/<encodedPath>/agent-transcripts/<uuid>/<uuid>.jsonl",
            "projects/<encodedPath>/subagents/*.jsonl",
            "sessions/<encodedPath>/session-<uuid>/session.jsonl.zstd",
            "file-history/<name:sessionID>",
            "todos/<name:sessionID>-agent-<name:sessionID>.json",
            "skills/**",
            "settings*.json",
        ]
        for source in sources {
            let once = try! PathPattern(source)
            let canonical = once.canonicalString
            guard let twice = try? PathPattern(canonical) else {
                XCTFail("模式 \(source) 的规范形式 \(canonical) 无法被再次解析")
                continue
            }
            XCTAssertEqual(once, twice, "模式 \(source) 往返后应等价")
            XCTAssertEqual(once.canonicalString, twice.canonicalString)
        }
    }

    func test带标签的uuid写成规范形式() {
        let pattern = try! PathPattern("rollout-<uuidA>.jsonl")
        XCTAssertEqual(pattern.canonicalString, "rollout-<uuid:A>.jsonl")
    }

    func test小写开头的具名占位段写成显式形式() {
        let pattern = try! PathPattern("file-history/<name:sessionID>")
        XCTAssertEqual(pattern.canonicalString, "file-history/<name:sessionID>")
    }

    // MARK: 非法模式

    func test空模式被拒绝() {
        XCTAssertThrowsError(try PathPattern("")) { error in
            XCTAssertEqual(error as? RuleFormatError, .emptyPattern)
        }
    }

    func test未闭合的占位符被拒绝() {
        XCTAssertThrowsError(try PathPattern("projects/<encodedPath/<uuid>.jsonl")) { error in
            guard case .unterminatedPlaceholder = error as? RuleFormatError else {
                return XCTFail("应报未闭合占位符，实际：\(error)")
            }
        }
    }

    func test没有日期分量的日期占位符被拒绝() {
        XCTAssertThrowsError(try PathPattern("sessions/<date>/rollout.jsonl")) { error in
            guard case .invalidPlaceholder(let source) = error as? RuleFormatError else {
                return XCTFail("应报非法占位符，实际：\(error)")
            }
            XCTAssertEqual(source, "<date>")
        }
    }

    func test空的路径分段被拒绝() {
        XCTAssertThrowsError(try PathPattern("projects//<uuid>.jsonl")) { error in
            XCTAssertEqual(error as? RuleFormatError, .emptySegment)
        }
    }

    func test递归通配只能整段出现() {
        XCTAssertThrowsError(try PathPattern("skills/**/cache")) { error in
            guard case .invalidRecursiveWildcard(let source) = error as? RuleFormatError else {
                return XCTFail("应报递归通配符位置非法，实际：\(error)")
            }
            XCTAssertEqual(source, "skills/**/cache")
        }
        XCTAssertNoThrow(try PathPattern("skills/**"))
    }

    func test错误描述对人来可读() {
        let description = RuleFormatError.unterminatedPlaceholder.errorDescription ?? ""
        XCTAssertFalse(description.isEmpty)
        XCTAssertTrue(description.contains("占位符"))
    }
}
