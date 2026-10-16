import SwiftUI

import AIMacCleanDomain

/// 发现与确认页（issue #16；PRD §9「发现与确认页：候选列表、置信度标识、确认/忽略、已确认工具管理」）。
///
/// 视图保持很薄：分组、折叠状态、可访问性文案都由 `DiscoveryPageModel` 算好，
/// 这里只做渲染与转发。因此这一页的行为可以在没有窗口的情况下测。
///
/// **诚实展示**（spec #7「展示与诚实」）：本阶段只列候选与置信度，
/// 不显示体积占位、不显示分类、不暗示任何归档收益。
public struct DiscoveryView: View {

    @ObservedObject private var model: DiscoveryPageModel

    /// 分类明细页（issue #27）的呈现开关。
    ///
    /// 深扫的入口是「已确认工具」（PRD §4.1 第 4 步），因此入口挂在已确认工具一栏上。
    /// 概览页（#28）落地后，同一份 `ClassificationDetailView` 也会从那里进入。
    @State private var showsClassificationDetail = false

    public init(model: DiscoveryPageModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                issueSection
                permissionSection
                pendingSection
                confirmedSection
                ignoredSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(L10n.text(.discoveryPageTitle))
        .task { model.load() }
        .sheet(isPresented: $showsClassificationDetail) {
            ClassificationDetailView(model: .standard())
                .frame(minWidth: 720, minHeight: 520)
        }
    }

    private var header: some View {
        HStack {
            Text(L10n.text(.discoveryStageNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.state.isScanning {
                // 扫描在后台跑（issue #21）：界面保持可交互，并如实说明正在做什么。
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text(.discoveryScanning))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.text(.discoveryScanning))
            }
            Button(L10n.text(.discoveryReload)) { model.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.state.isScanning)
                .accessibilityLabel(L10n.text(.discoveryReload))
        }
    }

    @ViewBuilder
    private var issueSection: some View {
        let texts = model.issueTexts
        if !texts.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(texts, id: \.self) { text in
                        // 语义色：浅色深色下都由系统决定前景/背景对比，不硬编码单一配色
                        // （User Story 38）。
                        Label(text, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var permissionSection: some View {
        if let title = model.permissionNoticeTitle {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    // 明确列出哪些位置因此无法扫描（PRD §4.4、User Story 37）。
                    ForEach(model.permissionNoticeTexts, id: \.self) { text in
                        Text(text).font(.callout).foregroundStyle(.secondary)
                    }
                    Text(model.permissionNoticeFootnote)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text(.discoverySectionPending)).font(.title3)

            if let failure = model.actionFailureText {
                Text(failure).foregroundStyle(Color.secondary).font(.callout)
            }

            if model.state.pendingGroups.isEmpty {
                Text(L10n.text(.discoveryEmptyPending))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.state.pendingGroups) { group in
                    CandidateGroupView(group: group, model: model)
                }
            }
        }
    }

    @ViewBuilder
    private var confirmedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text(.discoverySectionConfirmed)).font(.title3)
                Spacer()
                if !model.state.confirmedTools.isEmpty {
                    // 深扫只跑在已确认工具上：没有确认过任何工具时不摆这个入口。
                    Button(L10n.text(.classificationPageTitle)) { showsClassificationDetail = true }
                        .accessibilityLabel(L10n.text(.classificationPageTitle))
                }
            }
            if model.state.confirmedTools.isEmpty {
                Text(L10n.text(.discoveryEmptyConfirmed)).foregroundStyle(.secondary)
            } else {
                ForEach(model.state.confirmedTools) { row in
                    ToolRowView(
                        title: row.displayPath,
                        subtitle: row.record.toolIdentifier,
                        actionTitle: L10n.text(.discoveryActionForget)
                    ) {
                        model.forgetConfirmedTool(toolRootPath: row.record.toolRootPath)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var ignoredSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(.discoverySectionIgnored)).font(.title3)
            if model.state.ignoredCandidates.isEmpty {
                Text(L10n.text(.discoveryEmptyIgnored)).foregroundStyle(.secondary)
            } else {
                ForEach(model.state.ignoredCandidates) { row in
                    ToolRowView(
                        title: row.displayPath,
                        subtitle: row.record.toolIdentifier,
                        actionTitle: L10n.text(.discoveryActionRestore)
                    ) {
                        model.forgetIgnoredCandidate(toolRootPath: row.record.toolRootPath)
                    }
                }
            }
        }
    }
}

/// 一个置信度分组（「疑似」档默认折叠，User Story 4）。
private struct CandidateGroupView: View {

    let group: CandidateGroup
    @ObservedObject var model: DiscoveryPageModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    model.toggleExpanded(for: group.tier)
                } label: {
                    HStack {
                        Text(model.groupTitle(for: group.tier))
                            .font(.headline)
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                            .foregroundStyle(Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.groupTitle(for: group.tier))
                .accessibilityValue(
                    group.isExpanded ? L10n.text(.discoveryGroupExpanded) : L10n.text(.discoveryGroupCollapsed)
                )

                if group.isExpanded {
                    ForEach(group.candidates, id: \.toolRootPath) { candidate in
                        CandidateRowView(candidate: candidate, model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 一个候选行：路径、置信度、命中信号，以及「确认是 AI 工具」「忽略」两个动作。
private struct CandidateRowView: View {

    let candidate: Candidate
    @ObservedObject var model: DiscoveryPageModel

    private var presentation: CandidatePresentation { model.presentation(for: candidate) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(candidate.displayPath).font(.body).fontWeight(.medium)
                confidenceBadge
                Spacer()
            }

            if let name = candidate.ruleDisplayName {
                Text(name).font(.caption).foregroundStyle(.secondary)
            }

            if !presentation.signalTexts.isEmpty {
                // 当初命中的信号摆在这里，几个月后仍能理解这个判断是怎么来的（User Story 19）。
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(presentation.signalTexts, id: \.self) { text in
                        Text(text).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if !presentation.demotionTexts.isEmpty {
                ForEach(presentation.demotionTexts, id: \.self) { text in
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button(L10n.text(.discoveryActionConfirm)) {
                    model.performDefaultAction(onToolRootPath: candidate.toolRootPath)
                }
                .keyboardShortcut(.return, modifiers: [])
                .accessibilityLabel(L10n.text(.discoveryActionConfirm))
                .accessibilityHint(presentation.accessibilityLabel)

                Button(L10n.text(.discoveryActionIgnore)) {
                    model.performSecondaryAction(onToolRootPath: candidate.toolRootPath)
                }
                .keyboardShortcut("i", modifiers: .command)
                .accessibilityLabel(L10n.text(.discoveryActionIgnore))
                .accessibilityHint(presentation.accessibilityLabel)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
        // 焦点落在这一行时，辅助技术读出「路径 + 置信度」，值里带上「疑似」与信号。
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
        .focusable()
    }

    /// 置信度标识。颜色一律取语义色（`.secondary` / `.tertiary`），
    /// 因此浅色与深色下都由系统决定对比度（User Story 38）。
    private var confidenceBadge: some View {
        HStack(spacing: 4) {
            Text(model.confidenceText(for: candidate.confidence))
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.18), in: Capsule())
            if candidate.isSuspicious {
                // 「疑似」必须清晰可见，且**不只**靠颜色表达（User Story 4、42）。
                Text(L10n.text(.discoverySuspiciousBadge))
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.18), in: Capsule())
                    .accessibilityLabel(L10n.text(.discoverySuspiciousBadge))
            }
        }
    }
}

/// 已确认 / 已忽略列表里的一行：一个路径 + 一个动作。
private struct ToolRowView: View {

    let title: String
    let subtitle: String?
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(actionTitle, action: action)
                // 动作名 + 具体是哪一行，辅助技术读出来才不会分不清。
                .accessibilityLabel([actionTitle, title].joined(separator: "："))
        }
    }
}
