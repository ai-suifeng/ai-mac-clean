import SwiftUI

/// 主窗口外壳：一个侧边栏 + 一个空的分栏占位（PRD §9 的分栏结构）。
///
/// 本票（#8）不实现任何交互；各分栏的候选列表、占用数字与操作按钮由后续票填入。
public struct WorkspaceShellView: View {
    @State private var model = WorkspaceShellModel()

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(WorkspaceSection.allCases, selection: $model.selection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .accessibilityLabel(section.accessibilityLabel)
            }
            .navigationTitle("AI 记录瘦身")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            SectionPlaceholderView(section: model.selection)
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
