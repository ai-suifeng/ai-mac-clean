import Foundation
import XCTest

/// 一次「测试触碰了真实 AI 工具数据目录」的违规。
struct RealToolDirectoryViolation: Error, CustomStringConvertible {
    /// 被测代码给出的路径（已归一化为绝对路径）。
    let path: String
    /// 命中的禁区根。
    let root: ForbiddenRealToolDirectory

    /// 人读的报告：违规路径 + 命中的禁区根 + 来源。
    func report(source: String) -> String {
        """
        测试触碰真实 AI 工具数据目录（issue #14 护栏）
          路径：\(path)
          禁区：\(root.homeRelativePath)（\(root.expandedPath)）
          来源：\(source)
        """
    }

    var description: String {
        report(source: "未标注")
    }
}

/// Seam A2：判定一条路径是否落在真实 AI 工具数据目录之下。
///
/// 判定只做字符串比较——**不 stat、不列目录、不读文件**。真实目录永远不被触碰，
/// 护栏自己也不例外（issue #14 的硬性要求）。
struct RealToolDirectoryGuard {
    let list: ForbiddenRealToolDirectoryList

    /// 当前用户主目录下的护栏实例。清单读不出来就直接崩：护栏不能「读不到就放行」。
    static var live: RealToolDirectoryGuard {
        // 读不到清单属于仓库损坏/环境异常，用 fatalError 让整轮测试立刻失败。
        let list: ForbiddenRealToolDirectoryList
        do {
            list = try ForbiddenRealToolDirectoryList.load()
        } catch {
            fatalError("无法加载禁区清单，护栏拒绝放行：\(error)")
        }
        return RealToolDirectoryGuard(list: list)
    }

    init(list: ForbiddenRealToolDirectoryList) {
        self.list = list
    }

    /// 判定路径；落在禁区之下时返回违规，否则返回 nil。
    ///
    /// - Parameters:
    ///   - path: 被测代码给出的路径，绝对或相对均可。
    ///   - workingDirectory: 相对路径的基准，默认当前工作目录。
    func violation(forPath path: String, workingDirectory: String? = nil) -> RealToolDirectoryViolation? {
        let absolute = absolutize(path, workingDirectory: workingDirectory)

        for root in list.roots {
            if isContained(absolute, in: root.expandedPath) {
                return RealToolDirectoryViolation(path: absolute, root: root)
            }
        }
        return nil
    }

    /// 把路径变成归一化后的绝对路径：相对路径接上工作目录（相对工作目录仍为相对）。
    private func absolutize(_ path: String, workingDirectory: String?) -> String {
        let normalized = PathNormalization.normalized(path, homeDirectory: list.homeDirectory)
        guard !normalized.hasPrefix("/") else { return normalized }

        let base = PathNormalization.normalized(
            workingDirectory ?? FileManager.default.currentDirectoryPath,
            homeDirectory: list.homeDirectory
        )
        return PathNormalization.normalized(base + "/" + normalized, homeDirectory: list.homeDirectory)
    }

    /// `path` 是否等于 `root` 或位于其之下（大小写不敏感，macOS 默认文件系统如此）。
    private func isContained(_ path: String, in root: String) -> Bool {
        let candidate = path.lowercased()
        let boundary = root.lowercased()
        if candidate == boundary { return true }
        return candidate.hasPrefix(boundary + "/")
    }
}

extension XCTestCase {
    /// Seam A3：被测代码每给出一条路径就该过一次护栏；违规即让测试立刻失败。
    ///
    /// `source` 是调用点自己写的出处，便于在失败信息里定位是哪条路径漏了出来。
    func assertNotTouchingRealToolDirectory(
        _ path: String,
        source: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let violation = RealToolDirectoryGuard.live.violation(forPath: path) {
            XCTFail(
                violation.report(source: source()) + "\n  断言位置：\(file):\(line)",
                file: file,
                line: line
            )
        }
    }
}
