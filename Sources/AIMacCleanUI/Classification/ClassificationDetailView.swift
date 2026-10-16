import SwiftUI

import AIMacCleanDomain

/// 分类明细页（issue #27；PRD §5.1 四类与处理方式、§9、§14.1）。
///
/// 每台已确认工具一区：四类各自的字节数、文件数、占比，按子路径列出主要占用项；
/// 不可归档的三类各自带 PRD §5.1 的处理说明；可归档占比极小的工具被如实标注；
/// 读不到的位置逐条列出。
///
/// 视图保持很薄：顺序、文案、占比、可访问性文字都由 `ClassificationDetailPageModel`
/// 与 `ClassificationDetailPresenter` 算好，这里只做渲染与转发。
///
/// **诚实展示**：这一页不出现任何压缩率或「预计腾出多少」，也不给可归档的四类
/// 任何「现在就点得动」的入口——本阶段（M2）一个文件都不写。
public struct ClassificationDetailView: View {

    @ObservedObject private var model: ClassificationDetailPageModel

    public init(model: ClassificationDetailPageModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                issueSection
                if model.state.isEmpty {
                    Text(model.emptyText)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.state.details) { detail in
                    ToolClassificationDetailSection(detail: detail)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(model.titleText)
        .task { model.load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.stageNoteText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.state.isScanning {
                // 深扫在后台跑（issue #21 的教训）：界面保持可交互，并如实说明正在做什么。
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.scanningText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(model.scanningText)
            }

            Button(model.reloadTitleText) { model.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.state.isScanning)
                .accessibilityLabel(model.reloadTitleText)
        }
    }

    @ViewBuilder
    private var issueSection: some View {
        let texts = model.issueTexts
        if !texts.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(texts, id: \.self) { text in
                        // 语义色：浅色深色下都由系统决定对比度，不硬编码配色。
                        Label(text, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// 一台工具的一区：四类占用 + 根拆分 + 读不到的位置。
private struct ToolClassificationDetailSection: View {

    let detail: ToolClassificationDetail

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                titleRow
                archivableShareRow
                categoryList
                rootBreakdown
                unreadableSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 焦点落在这一区时，辅助技术读出「哪台工具 + 合计 + 可归档占比」。
        .accessibilityElement(children: .contain)
        .accessibilityLabel(detail.accessibilityLabel)
        .accessibilityValue(detail.accessibilityValue)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(detail.displayName)
                .font(.title3)
                .accessibilityLabel(detail.accessibilityLabel)
            Text(detail.rootDisplayPath)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(detail.totalSizeText).font(.headline)
                Text(detail.totalFileCountText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var archivableShareRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.format(.classificationArchivableShareLabel, [detail.archivableShareText]))
                .font(.callout)
                .foregroundStyle(Color.secondary)

            if let notice = detail.tinyArchivableShareNotice {
                // 收益极低的工具如实标注（PRD §9、§14.1：Claude Code 只有 0.15%）：
                // 不大字号、不换算成收益，也不出现任何压缩率。
                Label(notice, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    private var categoryList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(detail.categoryRows) { row in
                CategoryRowView(row: row)
            }
        }
    }

    @ViewBuilder
    private var rootBreakdown: some View {
        if detail.showsRootBreakdown {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(detail.rootRows) { root in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(root.roleText).font(.caption).foregroundStyle(.secondary)
                        Text(root.displayPath).font(.caption)
                        Spacer()
                        Text(root.sizeText).font(.caption)
                        Text(root.fileCountText).font(.caption).foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(root.accessibilityLabel)
                    if let note = root.noteText {
                        Text(note).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var unreadableSection: some View {
        if detail.hasUnreadableEntries {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(.classificationUnreadableTitle))
                    .font(.callout)
                // 逐条列出**具体位置**与原因（PRD §4.4）。
                ForEach(detail.unreadableRows) { row in
                    Text(row.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(row.accessibilityLabel)
                }
                Text(L10n.text(.classificationUnreadableFootnote))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// 一个类别的一行：类别名 + 处理方式 + 尺寸 / 文件数 / 占比 + 子路径明细。
private struct CategoryRowView: View {

    let row: ClassificationCategoryRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.nameText).font(.headline)
                Spacer()
                Text(row.sizeText).font(.body)
                Text(row.fileCountText).font(.caption).foregroundStyle(.secondary)
                Text(L10n.format(.classificationCategoryShare, [row.shareText]))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 处理方式逐字来自 PRD §5.1——不可归档的三类靠这句话把承诺说清楚。
            Text(row.handlingText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let note = row.noteText {
                Text(note).font(.caption2).foregroundStyle(.tertiary)
            }

            if !row.summaries.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(.classificationSummaryTitle))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(row.summaries) { summary in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(summary.text).font(.caption)
                            if let attribution = summary.attributionText {
                                Text(attribution).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if row.hiddenSummaryCount > 0 {
                        Text(L10n.format(.classificationSummaryMore, ["\(row.hiddenSummaryCount)"]))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        // 键盘可达，且辅助技术读到「类别 + 尺寸 + 占比 + 处理方式」。
        .focusable()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
    }
}
