import Foundation

import AIMacCleanRules

/// 四类占用的一行：概览页「四类分列」的一格（PRD §5.1、PRD §9）。
///
/// 单独成类型而不是让界面直接遍历 `CategoryOccupancy`：`CategoryOccupancy` 只列出
/// **确实有数据**的类别（深扫的纪律：没有数据的类别不留占位空行），而概览页要的是
/// **四行齐全**的固定版式。补齐这一步放在 Domain，界面因此不必认识规则层的
/// `DataCategory`（UI 只依赖 Domain）。
///
/// 这里**不带文案**：类别名与处理方式由界面层的 `CategoryCopy` 从本地化目录取，
/// 概览页与明细页因此说的是同一句话（同一条文案只有一处）。
public struct CategoryOccupancyLine: Equatable, Sendable {

    /// 类别本身（四类封闭枚举）。界面据此取文案与列表身份。
    public let category: DataCategory

    /// 类别标识（`DataCategory.rawValue`），供界面做列表身份与测试断言。
    public var categoryID: String { category.rawValue }

    /// 本类的占用；没有数据的类别是 `Occupancy()`（0 字节 / 0 文件），不是缺失。
    public let occupancy: Occupancy

    /// 本阶段（M2）能否归档。恒为 `false`：归档能力属于 M3。
    public let isArchivableNow: Bool

    public init(
        category: DataCategory,
        occupancy: Occupancy,
        isArchivableNow: Bool
    ) {
        self.category = category
        self.occupancy = occupancy
        self.isArchivableNow = isArchivableNow
    }
}

extension ToolScanReport {

    /// 本工具的四类分列：**四行齐全**，顺序固定为 PRD §5.1 的表格顺序。
    public var categoryLines: [CategoryOccupancyLine] {
        DataCategory.displayOrder.map { category in
            CategoryOccupancyLine(
                category: category,
                occupancy: self.category(category)?.occupancy ?? Occupancy(),
                isArchivableNow: category.isArchivableNow
            )
        }
    }

    /// 本工具「可归档占比」= 可归档字节 / 本工具总占用（总占用为 0 时返回 0）。
    ///
    /// 算法只有一处：`ArchivableShare.share(of:totalBytes:)`。
    public var archivableShare: Double {
        ArchivableShare.share(of: archivableOccupancy.bytes, totalBytes: occupancy.bytes)
    }

    /// 这台工具的收益是不是低到必须如实标注（PRD §9）。
    ///
    /// 两个条件缺一不可：**确实有可归档字节**（否则 0 不叫「极小」，叫「没有」，
    /// 该由数字本身说明），且占比低于门槛。判定与门槛都只有一处：
    /// `ArchivableShare.isNegligible(archivableBytes:totalBytes:)`。
    public var isArchivableShareNegligible: Bool {
        ArchivableShare.isNegligible(archivableBytes: archivableOccupancy.bytes, totalBytes: occupancy.bytes)
    }
}

extension DeepScanReport {

    /// 全体工具的四类分列（逐类求和）：**四行齐全**，顺序固定为 PRD §5.1。
    public var categoryLines: [CategoryOccupancyLine] {
        DataCategory.displayOrder.map { category in
            let occupancy = Occupancy.sum(toolReports.compactMap { $0.category(category)?.occupancy })
            return CategoryOccupancyLine(
                category: category,
                occupancy: occupancy,
                isArchivableNow: category.isArchivableNow
            )
        }
    }
}
