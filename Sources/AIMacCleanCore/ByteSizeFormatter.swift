import Foundation

/// 全应用唯一的体积格式化入口（PRD §9「大小统一用 ByteCountFormatter」）。
///
/// 上层视图与未来的扫描、归档、还原结果都必须走这里，避免同一份数字在不同页面有不同写法。
public enum ByteSizeFormatter {

    /// 把字节数格式化成展示用字符串，例如 `12 GB`、`1023 B`。
    ///
    /// 实现基于 `ByteCountFormatter`，但固定为 1024 进制的 `.binary` 风格：
    /// 默认的 `.file` 风格会把 1023 字节显示成 `1 KB`、把 1 GiB 显示成 `1.07 GB`，
    /// 对一个以「如实展示占用」为卖点的应用来说属于夸大，故不采用。
    /// 结果再统一成短单位（`B` / `KB` / `MB` / `GB` / `TB`）并去掉千分位分隔符，
    /// 使同一份数字在任何系统语言下都一样。
    public static func string(from byteCount: Int64) -> String {
        // 负数不是可展示的体积（例如文件已被外部删除导致 stat 出现负值），按 0 呈现。
        let bytes = max(0, byteCount)
        return normalize(formatter.string(fromByteCount: bytes))
    }

    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = .useAll
        // 不显示「1 GB (1,073,741,824 bytes)」这种双重写法。
        formatter.includesActualByteCount = false
        formatter.zeroPadsFractionDigits = false
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    /// 把 `ByteCountFormatter` 的输出收敛成唯一一种写法：`<数字> <单位>`，中间一个普通空格。
    ///
    /// 它的原始输出有两个不稳定点，本机实测都能触发：
    /// 数字与单位之间的空格不是 ASCII 空格（中文系统下实测为不可断空格 / 全角空格）；
    /// 字节档位的单位词随系统语言变化（中文下是「0 字节」，英文下是 "0 bytes"）。
    /// 不收敛的话，同一个数字会因为用户的系统语言而长得不一样（PRD §9 要求统一格式）。
    private static func normalize(_ raw: String) -> String {
        // 1) 数字与单位按「所有空白」切分，各种不可断空格都会落进同一个空隙里。
        let parts = raw
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        guard let number = parts.first else { return "0 B" }

        // 2) 去掉千分位分隔符（"1,023 bytes" → "1023 B"）。
        let digits = number.replacingOccurrences(of: ",", with: "")

        // 3) 单位统一成大写短单位。
        let unit = parts.dropFirst().joined().uppercased()
        switch unit {
        case "B", "BYTE", "BYTES", "字节":
            return "\(digits) B"
        case "KB", "MB", "GB", "TB", "PB":
            return "\(digits) \(unit)"
        default:
            return "\(digits) B"
        }
    }
}
