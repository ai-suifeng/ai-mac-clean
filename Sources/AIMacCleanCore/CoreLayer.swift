import Foundation

/// Core 层：平台无关的基础设施（PRD §10）。
///
/// 本层只依赖 Foundation，不引用任何上层，也不触碰真实工具数据目录。
public enum CoreLayer {
    /// 层标识，供上层在日志与报错里指明出处。
    public static let layerIdentifier = "Core"

    /// Core 允许依赖的层：为空。Core 之下再无其它层。
    public static let allowedDependencyLayerIdentifiers: Set<String> = []
}
