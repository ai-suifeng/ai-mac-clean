import SwiftUI

/// 主窗口外壳：一个侧边栏 + 一个分栏内容区（PRD §9 的分栏结构）。
///
/// 本阶段（issue #16）只有「发现与确认」是真实页面，其余四个分栏是占位，
/// 且占位文案不说任何本阶段还做不到的事。
public struct WorkspaceShellView: View {

    @State private var model: WorkspaceShellModel
    private let discoveryPageModel: DiscoveryPageModel

    /// 用生产接线（真实规则目录、`/Applications`、PATH 与本机确认存储）构造外壳。
    public init() {
        self.init(discoveryPageModel: .standard())
    }

    /// 注入一个发现与确认页的视图模型（测试与预览用）。
    public init(discoveryPageModel: DiscoveryPageModel) {
        self.discoveryPageModel = discoveryPageModel
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
            case .discovery:
                DiscoveryView(model: discoveryPageModel)
            default:
                SectionPlaceholderView(section: model.selection)
            }
        }
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
