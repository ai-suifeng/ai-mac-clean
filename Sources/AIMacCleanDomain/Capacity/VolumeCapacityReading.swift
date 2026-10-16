import Foundation

/// 「读某个路径**所在卷**的容量」这件事本身（ticket #24）。
///
/// 收成协议是为了可注入：测试给固定读数，不依赖本机磁盘实况（ticket #24 验收）。
/// 概览页将来也只依赖这个协议，因此它的测试同样不必碰真磁盘。
///
/// ## 边界
///
/// - **只读调用方给的那一个路径**：不列举目录、不枚举任何通用位置。
///   浅扫「只碰规则声明的位置」的纪律（#18/#19）在这里同样成立。
/// - `path` 由调用方保证是自己有权访问的路径（例如已确认工具的工具根）。
///   本接口不做授权判定——它只看卷容量，看不到目录内容。
/// - 读不到时返回 `.unknown(...)`，**不抛错、不崩溃、不返回 0**。
public protocol VolumeCapacityReading {

    /// 读 `path` 所在卷的容量。
    func capacity(ofVolumeContaining path: String) -> VolumeCapacity
}

/// `VolumeCapacityReading` 的真实实现：走 `URL.resourceValues(forKeys:)`，
/// **不 shell 调用 `df`**（ticket #24 验收）。
public struct SystemVolumeCapacityReader: VolumeCapacityReading {

    /// 一个路径所在卷的系统**原始**读数：系统报了什么，还没判定可用性。
    ///
    /// 之所以不直接用 `URLResourceValues` 当接缝：它的属性只读，测试造不出可控样本；
    /// 而本机磁盘实况不允许进测试（spec #22「真实数据目录绝不参与」）。
    public struct Values: Equatable, Sendable {

        /// `volumeAvailableCapacityForImportantUsage`：含可清理空间的可用量。
        public var availableForImportantUsage: Int64?

        /// `volumeAvailableCapacity`：不含可清理空间的可用量，仅在前者缺失时兜底。
        public var available: Int64?

        /// `volumeTotalCapacity`：卷的总容量。
        public var total: Int64?

        public init(
            availableForImportantUsage: Int64? = nil,
            available: Int64? = nil,
            total: Int64? = nil
        ) {
            self.availableForImportantUsage = availableForImportantUsage
            self.available = available
            self.total = total
        }
    }

    /// 真实读数来源：只问传入的那一个 URL，只问容量相关的 key。
    public static let systemValuesSource: (String) throws -> Values = { path in
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey,
        ])
        return Values(
            availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage,
            available: values.volumeAvailableCapacity.map(Int64.init),
            total: values.volumeTotalCapacity.map(Int64.init)
        )
    }

    /// 系统读数来源；默认走真实文件系统，测试注入固定值。
    private let valuesSource: (String) throws -> Values

    public init(
        valuesSource: @escaping (String) throws -> Values = SystemVolumeCapacityReader.systemValuesSource
    ) {
        self.valuesSource = valuesSource
    }

    public func capacity(ofVolumeContaining path: String) -> VolumeCapacity {
        guard let values = try? valuesSource(path) else {
            return .unknown(.volumeUnreadable)
        }
        guard let total = values.total, let available = values.availableForImportantUsage else {
            return .unknown(.capacityNotReported)
        }
        return .measured(availableBytes: available, totalBytes: total)
    }
}
