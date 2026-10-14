import Foundation

/// Domain 层边界（PRD §10）：工具、候选、置信度、确认记录等领域模型与应用服务接口。
///
/// 本票（#8）只建立骨架。结构指纹发现（issue #12）与确认存储（issue #13）
/// 会把下面的占位替换成真正的模型。UI 层只依赖本层，不直接触碰 Rules 或 Core。
public enum DomainLayer {
    /// 层标识，供 UI / 后续票在日志与报错里指明出处。
    public static let layerIdentifier = "Domain"

    /// 本层允许依赖的层。
    public static let allowedDependencyLayerIdentifiers: Set<String> = ["Core", "Rules"]
}
