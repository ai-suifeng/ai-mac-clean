import Foundation

import AIMacCleanCore

/// 一份**占用**：字节数 + 文件数（issue #23）。
///
/// 两个数一起走，不自成两个平行的 `Int` / `Int64`——深扫要在「工具 / 类别 / 子路径」
/// 三种粒度上都同时回答「占了多少、是多少个文件」，而 `(12G, 3)` 与 `(12G, 30000)`
/// 对用户是完全不同的两件事（PRD §14.1 的实测大头之一就是「879M / 24,849 个文件」）。
///
/// 字节数的权威类型是 `Int64`（`ByteSizeFormatter` 与 `FileAttributeKey.size` 都是它）。
public struct Occupancy: Equatable, Hashable, Sendable, Comparable {

    /// 占用字节数。
    public let bytes: Int64

    /// 文件数。**只数文件**，不把目录算进去——目录占的块大小不是用户要回收的东西，
    /// 混进来只会让「多少文件」这个数说不清。空目录因此贡献 `0` 个文件。
    public let fileCount: Int

    public init(bytes: Int64 = 0, fileCount: Int = 0) {
        self.bytes = bytes
        self.fileCount = fileCount
    }

    /// 相加：一次扫描里它就是「把各部分汇总起来」的那一步。
    public func adding(_ other: Occupancy) -> Occupancy {
        Occupancy(bytes: bytes + other.bytes, fileCount: fileCount + other.fileCount)
    }

    /// 把一组占用相加。
    public static func sum(_ occupancies: some Sequence<Occupancy>) -> Occupancy {
        occupancies.reduce(Occupancy(), +)
    }

    public static func + (lhs: Occupancy, rhs: Occupancy) -> Occupancy { lhs.adding(rhs) }

    /// 是否什么都没占（既没有字节也没有文件）。
    public var isEmpty: Bool { bytes == 0 && fileCount == 0 }

    /// 占用的尺寸展示文案（`247 MB`）。
    ///
    /// 界面层只依赖 Domain、不直接引 Core，因此尺寸格式化从领域层出口出去；
    /// 底下仍然是全应用唯一的 `ByteSizeFormatter`（PRD §9「大小统一用 ByteCountFormatter」），
    /// 界面不另写一套格式化。
    public var sizeText: String { ByteSizeFormatter.string(from: bytes) }

    /// 排序先比字节、再比文件数；相同即相等。
    public static func < (lhs: Occupancy, rhs: Occupancy) -> Bool {
        if lhs.bytes != rhs.bytes { return lhs.bytes < rhs.bytes }
        return lhs.fileCount < rhs.fileCount
    }
}

extension Occupancy: CustomStringConvertible {
    /// 「12 GB / 3 个文件」——界面与断言共用同一种写法。
    public var description: String {
        "\(ByteSizeFormatter.string(from: bytes)) / \(fileCount) 个文件"
    }
}
