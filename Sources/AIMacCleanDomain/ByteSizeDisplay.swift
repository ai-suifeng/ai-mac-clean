import Foundation

import AIMacCleanCore

/// 体积的展示适配（UI 层只依赖 Domain，不直接引 Core 的 `ByteSizeFormatter`）。
///
/// 与 `ToolRootDisplay` 同一条理由：界面要展示数字，但分层约定是「UI 只依赖 Domain」。
/// 这里**只做格式化**，不做任何判定——大小怎么算、算进来哪些，都是深扫的事。
///
/// 全应用唯一的体积写法仍然是 `ByteSizeFormatter`（PRD §9「大小统一用 ByteCountFormatter」），
/// 这里不另起一套。
public enum ByteSizeDisplay {

    /// 把字节数格式化成展示用字符串，例如 `12 GB`、`1023 B`。
    public static func string(from bytes: Int64) -> String {
        ByteSizeFormatter.string(from: bytes)
    }
}
