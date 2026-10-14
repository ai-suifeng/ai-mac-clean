import Foundation

/// 设置项（PRD §10：「设置用 UserDefaults」）。
///
/// 与确认记录明确分开：记录是需要备份、需要被读出来解释的事实，因此走本机 JSON；
/// 设置是偏好，用 UserDefaults 即可，不值得为它单独发明一个文件。
///
/// UserDefaults 实例由调用方注入（应用传 `.standard`，测试传独立 suite），
/// 这样测试绝不会写进应用真实的 defaults 域（PRD §13 第 3 条）。
public final class ConfirmationSettings {

    /// 纯名称命中的候选是否默认折叠。默认 `true`。
    ///
    /// 依据 User Story 4 / PRD §4.3：纯名称命中的候选一律标为「疑似」并默认折叠，
    /// 用户看到的是安静、可信的列表而不是一堆 `~/.claudebak`。
    public var collapsesNameOnlyCandidates: Bool {
        get { defaults.object(forKey: Keys.collapsesNameOnlyCandidates) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.collapsesNameOnlyCandidates) }
    }

    /// 用户是否已经完成过第一轮的确认/忽略。默认 `false`。
    ///
    /// 记录本身就是「问过了」的证据（PRD §4.1 第 4 步），这项只是让界面能分清
    /// 「首次启动」与「日常启动」，便于决定要不要主动提示还有没有待确认的候选。
    /// PRD 未规定 M1 的设置项，这是本阶段最保守的取法：只记一个布尔，不预置任何用户没要求过的行为。
    public var hasCompletedFirstLaunchReview: Bool {
        get { defaults.bool(forKey: Keys.hasCompletedFirstLaunchReview) }
        set { defaults.set(newValue, forKey: Keys.hasCompletedFirstLaunchReview) }
    }

    private let defaults: UserDefaults

    /// - Parameter defaults: 写入哪个 UserDefaults。传 nil 表示 suite 不可用。
    public init?(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// 应用本体使用的入口。
    public static func standard() -> ConfirmationSettings? {
        ConfirmationSettings(defaults: .standard)
    }

    private enum Keys {
        static let collapsesNameOnlyCandidates = "collapsesNameOnlyCandidates"
        static let hasCompletedFirstLaunchReview = "hasCompletedFirstLaunchReview"
    }
}
