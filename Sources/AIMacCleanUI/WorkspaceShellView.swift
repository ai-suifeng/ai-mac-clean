import SwiftUI

/// 主窗口外壳：一个侧边栏 + 一个分栏内容区（PRD §9 的分栏结构）。
///
/// 真实页面：概览（issue #28）与发现与确认（issue #16）；其余三个分栏是占位，
/// 且占位文案不说任何本阶段还做不到的事。
public struct WorkspaceShellView: View {

    @State private var model: WorkspaceShellModel
    private let discoveryPageModel: DiscoveryPageModel
    private let overviewPageModel: OverviewPageModel

    /// 用生产接线（真实规则目录与本机确认存储）构造外壳。
    ///
    /// - Parameter language: 已实现页面的界面语言；`nil` 走 `L10n` 的基准语言（简体中文）。
    ///   概览页的四类分列与全部文案据此取本地化目录（`OverviewPageModel.standard`）；
    ///   发现与确认页当前还没有语言参数。
    public init(language: AppLanguage? = nil) {
        self.init(
            discoveryPageModel: .standard(),
            overviewPageModel: .standard(language: language)
        )
    }

    /// 注入一个发现与确认页的视图模型（测试与预览用）；概览页用生产接线。
    public init(discoveryPageModel: DiscoveryPageModel) {
        self.init(discoveryPageModel: discoveryPageModel, overviewPageModel: .standard())
    }

    /// 注入两个真实页面的视图模型（测试与预览用）。
    public init(discoveryPageModel: DiscoveryPageModel, overviewPageModel: OverviewPageModel) {
        self.discoveryPageModel = discoveryPageModel
        self.overviewPageModel = overviewPageModel
        _model = State(initialValue: WorkspaceShellModel())
    }

    public var body: some View {
        NavigationSplitView {
            List(WorkspaceSection.allCases, selection: $model.selection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .accessibilityLabel(section.accessibilityLabel)
            }
            .navigationTitle(L10n.text(.appTitle))
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch model.selection {
            case .overview:
                OverviewView(model: overviewPageModel)
            case .discovery:
                DiscoveryView(model: discoveryPageModel)
            default:
                SectionPlaceholderView(section: model.selection)
            }
        }
        // 恢复出来的窗口位置若落在所有屏幕的可见区域之外（多屏 / 显示布局变化），
        // 用户会看不到窗口、以为应用没起来。出现时收拢回主屏，见 `WindowPlacement`。
        .background(WindowFrameGuard())
    }
}

/// 分栏占位视图。
public struct SectionPlaceholderView: View {
    public let section: WorkspaceSection

    public init(section: WorkspaceSection) {
        self.section = section
    }

    public var body: some View {
        VStack(spacing: 12) {
            Label(section.title, systemImage: section.symbolName)
                .font(.title2)
            Text(section.placeholderMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
