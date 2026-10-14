import Foundation

/// 真实 AI 工具数据目录禁区清单的解析（issue #14）。
///
/// 唯一的清单来源是仓库里的 `TestSupport/ForbiddenRealToolDirectories.txt`：
/// Swift 断言层与 C 拦截器都读这一份文本，不在代码里各写一份清单。
///
/// 解析阶段就把每一条**字面展开成绝对路径**，此后所有判定都是字符串比较——
/// 护栏在任何时候都不会去读、列或 stat 这些真实目录本身。
enum ForbiddenRealToolDirectoryListError: Error, CustomStringConvertible {
    case empty
    case notAnchored(entry: String)
    case duplicate(entry: String)
    case unreadable(path: String, reason: String)

    var description: String {
        switch self {
        case .empty:
            return "禁区清单为空"
        case let .notAnchored(entry):
            return "禁区条目必须以 ~/ 开头或写成绝对路径：\(entry)"
        case let .duplicate(entry):
            return "禁区清单出现重复条目：\(entry)"
        case let .unreadable(path, reason):
            return "读不到禁区清单 \(path)：\(reason)"
        }
    }
}

/// 禁区清单里的一条真实目录。
struct ForbiddenRealToolDirectory: Equatable {
    /// 清单里的原始写法，如 `~/.claude`。
    let homeRelativePath: String
    /// 展开并归一化后的绝对路径，如 `/Users/example/.claude`。
    let expandedPath: String
}

/// 一份已解析、可直接用于判定的禁区清单。
struct ForbiddenRealToolDirectoryList: Equatable {
    /// 主目录，判定与展开都以它为锚。
    let homeDirectory: String
    let roots: [ForbiddenRealToolDirectory]

    /// 解析清单文本。`homeDirectory` 由调用方注入，因此解析本身也不会去读真实主目录。
    static func parse(_ text: String, homeDirectory: String) throws -> ForbiddenRealToolDirectoryList {
        let anchor = PathNormalization.normalized(homeDirectory, homeDirectory: homeDirectory)
        var roots: [ForbiddenRealToolDirectory] = []
        var seen: [String: String] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            guard line.hasPrefix("~/") || line.hasPrefix("/") else {
                throw ForbiddenRealToolDirectoryListError.notAnchored(entry: line)
            }

            let expanded = PathNormalization.normalized(line, homeDirectory: homeDirectory)
            // macOS 默认文件系统大小写不敏感，重复判定按小写比较。
            let key = expanded.lowercased()
            if seen[key] != nil {
                throw ForbiddenRealToolDirectoryListError.duplicate(entry: line)
            }
            seen[key] = line

            roots.append(ForbiddenRealToolDirectory(homeRelativePath: line, expandedPath: expanded))
        }

        guard !roots.isEmpty else {
            throw ForbiddenRealToolDirectoryListError.empty
        }

        return ForbiddenRealToolDirectoryList(homeDirectory: anchor, roots: roots)
    }

    /// 读取并解析仓库里的清单文件。
    ///
    /// - Parameter homeDirectory: 主目录，默认取当前用户主目录。
    /// - Parameter fileURL: 清单文件位置，默认按 `#filePath` 定位仓库里的
    ///   `TestSupport/ForbiddenRealToolDirectories.txt`；`AMC_TEST_GUARD_LIST`
    ///   环境变量可覆盖（C 拦截器读的是同一个文件，避免两边清单漂移）。
    static func load(
        fileURL: URL? = nil,
        homeDirectory: String = NSHomeDirectory()
    ) throws -> ForbiddenRealToolDirectoryList {
        let url = fileURL ?? Self.defaultListFileURL()
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ForbiddenRealToolDirectoryListError.unreadable(
                path: url.path,
                reason: "\(error)"
            )
        }
        return try parse(text, homeDirectory: homeDirectory)
    }

    /// 仓库内清单文件的规范位置：`TestSupport/ForbiddenRealToolDirectories.txt`。
    static var repositoryListFileURL: URL {
        defaultListFileURL()
    }

    private static func defaultListFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["AMC_TEST_GUARD_LIST"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        // 本文件位于 <repo>/Tests/AIMacCleanTests/Support/，向上三级即仓库根。
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()  // Support
            .deletingLastPathComponent()  // AIMacCleanTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // <repo>
            .appendingPathComponent("TestSupport/ForbiddenRealToolDirectories.txt")
    }
}

/// 纯字面的路径归一化：不读文件系统、不解析符号链接。
///
/// 护栏要在检查通过之后才允许任何 stat 发生，所以归一化必须是纯字符串运算。
/// 代价与取舍：符号链接不解析（见 `TestSupport/README.md`「已知边界」）。
enum PathNormalization {
    /// 展开 `~/`、压掉重复斜杠、去掉尾斜杠，并按字面消解 `.` 与 `..`。
    static func normalized(_ path: String, homeDirectory: String) -> String {
        var working = path
        if working == "~" {
            working = homeDirectory
        } else if working.hasPrefix("~/") {
            working = homeDirectory + working.dropFirst()
        }

        var isAbsolute = working.hasPrefix("/")
        var components: [String] = []
        for component in working.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if !isAbsolute {
                    // 相对路径里的前导 `..` 无法字面消解，原样保留。
                    components.append("..")
                }
                // 绝对路径里前导的 `..` 无处可去，直接丢弃。
            default:
                components.append(String(component))
            }
        }

        let joined = components.joined(separator: "/")
        if isAbsolute {
            return "/" + joined
        }
        return joined.isEmpty ? "." : joined
    }
}
