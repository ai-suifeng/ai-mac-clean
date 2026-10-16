import Foundation

/// 内置受保护路径判定所需要的路径运算。
///
/// 只做三件事：标准化、解析符号链接、按「根 + 相对路径」求相对路径。
/// 不做任何分类，也不读取文件内容（spec #7「本阶段完全不触碰任何文件内容」）。
enum ProtectedPathMath {

    /// 标准化绝对路径：去掉重复分隔符、尾随分隔符与 `.` / `..`。
    ///
    /// 不展开 `~`，也不解析符号链接——调用方决定用哪个形态做比较。
    static func normalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var stack: [String] = []

        for piece in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch piece {
            case ".":
                continue
            case "..":
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append("..")
                }
                // 绝对路径里的 `..` 越过根目录时按根目录处理（与 Foundation 一致）。
            default:
                stack.append(String(piece))
            }
        }

        guard isAbsolute || !stack.isEmpty else { return "" }
        let joined = stack.joined(separator: "/")
        return isAbsolute ? "/" + joined : joined
    }

    /// 拆出路径的各段（已标准化、已去掉分隔符）。
    static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// 求 `path` 相对 `root` 的相对路径；不在 `root` 之下时返回 `nil`。
    ///
    /// 比较前只做标准化，不解析符号链接——「链接所在的位置」与「链接的真实目标」
    /// 都要能被单独判定，符号链接解析由调用方显式选择。
    static func relativePath(of path: String, under root: String) -> String? {
        let pathComponents = components(of: normalize(path))
        let rootComponents = components(of: normalize(root))

        guard pathComponents.count >= rootComponents.count,
              Array(pathComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }

        return pathComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// 解析路径上存在的全部符号链接，返回真实目标。
    ///
    /// 路径不存在时不做任何假设：已存在的部分照常解析，剩下的部分原样拼回，
    /// 因此本函数不失败、不抛错（PRD §5.2「路径不存在时静默跳过」）。
    static func resolvingSymlinks(_ path: String) -> String {
        var pending = components(of: normalize(path))
        var resolved = "/"
        var hops = 0

        while let component = pending.first {
            pending.removeFirst()
            let candidate = resolved == "/" ? "/" + component : resolved + "/" + component

            guard isSymbolicLink(candidate) else {
                resolved = candidate
                continue
            }

            hops += 1
            guard hops <= 64,
                  let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate)
            else {
                // 循环链接或无法读取目标：保守地停在这里，不再继续展开。
                return candidate
            }

            let absoluteDestination = destination.hasPrefix("/")
                ? destination
                : (resolved == "/" ? "/" + destination : resolved + "/" + destination)
            pending = components(of: absoluteDestination) + pending
            resolved = "/"
        }

        return resolved
    }

    /// 判断某个已存在的路径是否为符号链接。
    static func isSymbolicLink(_ path: String) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// 通配符匹配：`*` 匹配任意字符；`matches(pattern:component:)` 只在单个路径段上比较，
    /// `matches(pattern:path:)` 比较的是相对路径，可包含 `/`（多段前缀模式，如 `.agents/skills*`）。
    ///
    /// 忽略大小写：macOS 默认文件系统大小写不敏感，忽略大小写只会多保护、不会少保护。
    static func matches(pattern: String, path: String) -> Bool {
        matches(patternCharacters: patternCharacters(of: pattern), characters: characters(of: path))
    }

    /// 忽略大小写的通配符匹配；`*` 匹配任意字符。
    static func matches(pattern: String, component: String) -> Bool {
        matches(pattern: pattern, path: component)
    }

    /// 预先把模式 / 文本转成小写字符数组（issue #29 的匹配热路径）。
    ///
    /// 深扫要对每个文件跑十几次模式匹配，而模式在一次扫描期间不变：把
    /// `Array(pattern.lowercased())` 从每次匹配挪到一次，5 万文件下省下的是实数。
    static func patternCharacters(of pattern: String) -> [Character] {
        Array(pattern.lowercased())
    }

    /// 文本 → 小写字符数组（与 `matches(patternCharacters:characters:)` 配套）。
    static func characters(of text: String) -> [Character] {
        Array(text.lowercased())
    }

    /// 与 `matches(pattern:path:)` **同一个算法**，只是两边的字符数组由调用方备好。
    static func matches(patternCharacters: [Character], characters: [Character]) -> Bool {
        var patternIndex = 0
        var componentIndex = 0
        var lastStarIndex = -1
        var resumeIndex = 0

        while componentIndex < characters.count {
            if patternIndex < patternCharacters.count,
               patternCharacters[patternIndex] == characters[componentIndex] {
                patternIndex += 1
                componentIndex += 1
            } else if patternIndex < patternCharacters.count,
                      patternCharacters[patternIndex] == "*" {
                lastStarIndex = patternIndex
                resumeIndex = componentIndex
                patternIndex += 1
            } else if lastStarIndex >= 0 {
                patternIndex = lastStarIndex + 1
                resumeIndex += 1
                componentIndex = resumeIndex
            } else {
                return false
            }
        }

        while patternIndex < patternCharacters.count, patternCharacters[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == patternCharacters.count
    }
}
