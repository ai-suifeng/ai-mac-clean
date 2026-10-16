import Foundation
import XCTest

/// 卷容量这块代码的**只读护栏**（ticket #24 验收：不产生任何写操作、不调用外部进程）。
///
/// 为什么是扫描源码而不是跑一遍看有没有写：一次容量读取碰的是真实卷，
/// 「没写」是**没有发生的事**，运行时观察不到；跑在只读文件系统上又要另造一套装载环境。
/// 因此像 `GlossarySynonymGuardTests` 那样，把这条承诺钉在源码文本上：
/// 只要有人往这里加了写文件的调用或起进程的调用，这条测试就红。
///
/// 扫描器本身先被「阳性对照」验过——它必须真的能认出违规写法，
/// 否则「扫出来是空的」只能证明扫描器坏了（与 issue #14 自检同一个思路）。
final class CapacityReadOnlyGuardTests: XCTestCase {

    // MARK: - 阳性对照

    func test扫描器能认出写操作与起进程的写法() {
        let offending = """
        let handle = FileHandle(forWritingTo: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/df")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        """

        XCTAssertEqual(
            Set(CapacityReadOnlyGuard.violations(in: offending)),
            ["write(to", "forWriting", "createDirectory", "Process(", "/bin/"]
        )
    }

    func test扫描器对只读写法不误报() {
        let clean = """
        let url = URL(fileURLWithPath: path)
        // 不 shell 调用 df：只问系统要卷容量。
        let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey])
        """

        XCTAssertEqual(CapacityReadOnlyGuard.violations(in: clean), [])
    }

    // MARK: - 真源码

    func test容量读取的源码里没有任何写操作或外部进程() throws {
        let sources = try CapacityReadOnlyGuard.sources()

        XCTAssertFalse(sources.isEmpty, "没找到 \(CapacityReadOnlyGuard.sourceDirectory.path) 下的源码。")
        for source in sources {
            XCTAssertEqual(
                CapacityReadOnlyGuard.violations(in: source.text),
                [],
                "\(source.name) 里出现了写操作或外部进程：容量读取必须是纯只读、零进程的。"
            )
        }
    }
}

/// 只读护栏的扫描器：从源码文本里挑出「会写盘」或「会起进程」的写法。
enum CapacityReadOnlyGuard {

    /// 违规写法的字面量。刻意收窄到**明确的**写入口与进程入口，不误伤只读 API。
    static let forbiddenTokens = [
        "Process(",
        "posix_spawn",
        "NSTask",
        "/bin/",
        "/usr/bin/",
        "createFile",
        "createDirectory",
        "createSymbolicLink",
        "removeItem",
        "copyItem",
        "moveItem",
        "replaceItem",
        "setAttributes",
        "write(to",
        "writeToFile",
        "forWriting",
        "truncate(",
    ]

    /// 本票的源码目录：`Sources/AIMacCleanDomain/Capacity`。
    static var sourceDirectory: URL {
        // 从本文件（Tests/AIMacCleanTests/…）上溯到仓库根。
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AIMacCleanDomain/Capacity", isDirectory: true)
    }

    struct Source: Equatable {
        let name: String
        let text: String
    }

    static func sources() throws -> [Source] {
        try FileManager.default
            .contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { Source(name: $0.lastPathComponent, text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// 一段源码里命中的违规写法（去重、保持字面量表的顺序）。
    static func violations(in source: String) -> [String] {
        forbiddenTokens.filter { source.contains($0) }
    }
}
