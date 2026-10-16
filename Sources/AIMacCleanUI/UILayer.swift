import Foundation

/// UI 层边界（PRD §10）：SwiftUI 视图。
public enum UILayer {
    /// 层标识，供日志与报错里指明出处。
    public static let layerIdentifier = "UI"

    /// 本层允许依赖的层：只依赖 Domain，间接用到 Core。
    public static let allowedDependencyLayerIdentifiers: Set<String> = ["Domain"]
}
