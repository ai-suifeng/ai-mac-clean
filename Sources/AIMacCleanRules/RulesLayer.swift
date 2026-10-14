import Foundation

/// Rules 层边界（PRD §10）：声明式规则模型、加载、规则集准入。
///
/// 本票（#8）只建立骨架。规则格式（issue #10）与规则集准入的保护单调性（issue #11）
/// 会把下面的占位替换成真正的模型；上层只应通过本层的公开接口访问规则能力。
public enum RulesLayer {
    /// 层标识，供 UI / 后续票在日志与报错里指明出处。
    public static let layerIdentifier = "Rules"

    /// 本层允许依赖的层。
    public static let allowedDependencyLayerIdentifiers: Set<String> = ["Core"]
}
