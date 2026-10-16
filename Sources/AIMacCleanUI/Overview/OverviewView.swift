import SwiftUI

import AIMacCleanDomain

/// 概览页（issue #28；PRD §9「总占用、各工具占用、可归档占比、磁盘剩余空间」）。
///
/// 视图保持很薄：汇总、排序、占比、辅助功能文案都由 `OverviewPageModel` 算好，
/// 这里只做渲染与转发。因此这一页的行为可以在没有窗口的情况下测。
///
/// ## 诚实展示（PRD §9、§14.1）
///
/// - 不出现压缩节省 / 搬迁腾出的估算——那两栏要实测抽样压缩与归档格式，属 M3。
/// - 收益极低的工具带一句「可归档占比极小」，占用数字不用大字号暗示收益。
/// - 「开始归档」不可用，并在按钮下方写清为什么（不是点了没反应）。
/// - 磁盘剩余空间读不到时显示「未知」，不显示 0。
public struct OverviewView: View {

    @ObservedObject private var model: OverviewPageModel

    public init(model: OverviewPageModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if model.isEmpty {
                    emptyState
                } else {
                    totalSection
                    categorySection
                    toolSection
                    diskSection
                    archiveSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(model.pageTitle)
        .task { model.load() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.stageNoteText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let scanning = model.scanningText {
                // 扫描在后台跑（issue #21）：界面保持可交互，并如实说明在做什么、
                // 以及上一轮结果还在（验收 6）。
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(scanning)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(scanning)
            }

            Button(model.reloadTitle) { model.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.state.isScanning)
                .accessibilityLabel(model.reloadTitle)
        }
    }

    // MARK: - 空状态（验收 5）

    @ViewBuilder
    private var emptyState: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let guidance = model.emptyGuidanceText {
                    Text(guidance)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 总占用与可归档占比（验收 1）

    @ViewBuilder
    private var totalSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if let total = model.totalText {
                    Text(total)
                        .font(.title3)
                        .accessibilityLabel(model.totalAccessibilityText ?? total)
                }
                if let share = model.archivableShareText {
                    // 可归档占比是**事实**，不是收益承诺：这里不写「可释放」，
                    // 也不放大字号（PRD §9）。
                    Text(share)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 四类分列（验收 1）

    @ViewBuilder
    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.categorySectionTitle).font(.title3)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.categoryRows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.title)
                            Text(row.handling)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(row.occupancyText)
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.accessibilityLabel)
                        .focusable()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 各工具占用（验收 1、2、3）

    @ViewBuilder
    private var toolSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.toolSectionTitle).font(.title3)
            ForEach(model.toolRows) { row in
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.displayName).font(.headline)
                            Text(row.displayPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(row.occupancyText).monospacedDigit()
                        }
                        Text(row.archivableText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let annotation = row.negligibleAnnotation {
                            // 如实的实话，不加任何正面的修饰（PRD §9、§14.1）。
                            Text(annotation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let displayOnly = row.displayOnlyText {
                            // 仅展示根绝不归档（PRD §2.3、§14.1）：它出现在占用里，
                            // 但必须说清楚它不在归档范围内。
                            Text(displayOnly)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.accessibilityLabel)
                .focusable()
            }
        }
    }

    // MARK: - 磁盘剩余空间（验收 7）

    @ViewBuilder
    private var diskSection: some View {
        if let free = model.freeSpaceText {
            Text(free)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel(free)
        }
    }

    // MARK: - 主按钮（验收 4）

    @ViewBuilder
    private var archiveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(model.archiveButtonTitle) {
                // 本阶段按钮恒不可用；动作留空是刻意的——不可用的按钮不该藏一个待接线的副作用。
            }
            .disabled(!model.archiveButtonIsEnabled)
            .accessibilityLabel(model.archiveButtonTitle)
            .accessibilityHint(model.archiveDisabledReason)

            // 为什么不可用必须写出来，不能让用户对着一个灰按钮猜（PRD §9）。
            Text(model.archiveDisabledReason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
