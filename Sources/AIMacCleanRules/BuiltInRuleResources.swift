import Foundation

/// 内置规则文件在包里的位置（issue #15；spec #7 User Story 20）。
///
/// 规则文件以 SwiftPM `resources` 的形式打进资源 bundle，本类型只给出它们的目录。
/// 这里**不认识任何工具名**：新增一个已知工具 = 在资源目录里放一个规则文件，
/// 软件本体与加载器都不需要改动。
public enum BuiltInRuleResources {

    /// 资源目录在 bundle 里的子目录名。
    public static let directoryName = "BundledRules"

    /// 内置规则文件所在目录。
    ///
    /// 资源缺失时返回 `nil` 而不是抛错：规则加载走 `RuleLoader.loadRules(inDirectory:)`，
    /// 目录不存在时它本来就会返回空结果（issue #10）。
    public static var directory: URL? {
        Bundle.module.resourceURL?.appendingPathComponent(directoryName, isDirectory: true)
    }
}
