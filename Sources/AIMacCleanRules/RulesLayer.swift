import Foundation

/// Rules 层边界（PRD §10）：声明式规则模型、加载、规则集准入。
///
/// 公开接口：
/// - 规则模型与加载器：`ToolRule` / `RuleLoader`（issue #10），格式见 `docs/rule-format.md`。
/// - 规则集准入：`RuleSetAdmission.admit(rules:homeDirectory:)`
///   （issue #11）。给出可用规则集 + 被拒绝的规则及各自原因；保护单调性由它把关，
///   不依赖上层自觉。
///
/// 上层只应通过本层的公开接口访问规则能力。
public enum RulesLayer {
    /// 层标识，供 UI / 后续票在日志与报错里指明出处。
    public static let layerIdentifier = "Rules"

    /// 本层允许依赖的层。
    public static let allowedDependencyLayerIdentifiers: Set<String> = ["Core"]
}
