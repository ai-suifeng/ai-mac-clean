import Foundation

import AIMacCleanCore

/// 卷容量（ticket #24）：某个路径**所在卷**的可用空间与总量，供概览页展示（PRD §9「磁盘剩余空间」）。
///
/// ## 为什么是一个枚举而不是两个可选数字
///
/// 「取不到容量」必须是**明确状态**，不能退化成 0：0 会被读成「盘满了」，
/// 于是用户看到的是「该腾地方了」这个错误的结论（ticket #24 验收）。
/// 反过来，真正的 0 是合法读数——盘确实满了，此时要如实显示，而不是被当成未知。
/// 两种事实用两个 case 分开，调用方就不可能把它们弄混。
///
/// ## 格式
///
/// 展示文本一律走 `ByteSizeFormatter`（PRD §9「大小统一用 ByteCountFormatter」），
/// 未知时给 `nil`，由界面决定不显示数字，而不是显示一个看起来像真的的 0 B。
public enum VolumeCapacity: Equatable, Sendable {

    /// 读到了容量。
    case measured(availableBytes: Int64, totalBytes: Int64)

    /// 读不到容量。**这是一个明确状态，不是 0**：0 会被读成「盘满了」，
    /// 让用户以为该腾地方了（ticket #24 验收）。
    case unknown(UnknownReason)

    /// 读不到容量的原因。分开的原因不同，界面能给的话也不同：
    /// 一个是「这台机器上读不到这个卷」，一个是「卷在，但系统没报容量」。
    public enum UnknownReason: Equatable, Sendable {

        /// 系统没能给出该路径所在卷的读数（路径不存在、无权限等）。
        case volumeUnreadable

        /// 读数拿到了，但里面没有可展示的容量数字：总量缺失或不为正、可用空间缺失或为负。
        case capacityNotReported
    }

    /// 剩余可用空间的展示文本；未知时为 `nil`。
    public var availableText: String? {
        guard case let .measured(availableBytes, _) = self else { return nil }
        return ByteSizeFormatter.string(from: availableBytes)
    }

    /// 总量（卷的总容量）的展示文本；未知时为 `nil`。
    public var totalText: String? {
        guard case let .measured(_, totalBytes) = self else { return nil }
        return ByteSizeFormatter.string(from: totalBytes)
    }
}
