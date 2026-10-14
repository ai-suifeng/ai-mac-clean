import Foundation

/// Rules 层边界（PRD §10）：声明式规则模型、加载、规则集准入。
///
/// 公开接口：
/// - 规则模型与加载器：`ToolRule` / `RuleLoader`（issue #10），格式见 `docs/rule-format.md`。
/// - 规则集准入的保护单调性校验（issue #11）尚未落地：上层不要假设「已验证的规则集」存在。
///
/// 上层只应通过本层的公开接口访问规则能力。
public enum RulesLayer {
    /// 层标识，供 UI / 后续票在日志与报错里指明出处。
    public static let layerIdentifier = "Rules"

    /// 本层允许依赖的层。
    public static let allowedDependencyLayerIdentifiers: Set<String> = ["Core"]
}
