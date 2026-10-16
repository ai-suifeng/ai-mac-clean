import XCTest

@testable import AIMacCleanUI

/// Seam D：主窗口分栏占位。分栏集合是 PRD §9 定下的契约，后续 UI 票在此之上填内容，
/// 所以这里钉住「有且只有这五个分栏、中文标题不重复」。
final class WorkspaceSectionTests: XCTestCase {

    func test分栏与PRD第9节一致() {
        XCTAssertEqual(
            WorkspaceSection.allCases.map(\.id),
            ["overview", "discovery", "archive", "archived", "settings"]
        )
    }

    func test分栏标题为中文且互不重复() {
        let titles = WorkspaceSection.allCases.map(\.title)
        XCTAssertEqual(
            titles,
            ["概览", "发现与确认", "归档", "已归档", "设置"]
        )
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    func test每个分栏都有可访问的名称() {
        for section in WorkspaceSection.allCases {
            XCTAssertFalse(section.accessibilityLabel.isEmpty, "\(section.id) 缺少辅助功能名称")
        }
    }

    func test默认停在发现与确认页() {
        // issue #16：概览页当时还是占位；issue #28 之后概览页也是真实页面，
        // 但默认落地页保持不变（先确认工具才有占用可看），断言的是「默认落在已实现的一页」。
        XCTAssertEqual(WorkspaceShellModel.defaultSelection, .discovery)
        XCTAssertTrue(WorkspaceShellModel.defaultSelection.isImplemented)
    }

    func test已实现的分栏是概览与发现与确认() {
        // issue #16 做了发现与确认页，issue #28 做了概览页；其余三个仍是占位。
        XCTAssertEqual(
            WorkspaceSection.allCases.filter(\.isImplemented),
            [.overview, .discovery],
            "已经做出来的分栏才允许摘掉占位文案"
        )
    }

    func test概览页的占位文案不再承诺本阶段做不到的事() {
        // 概览页已经实现，它取到的说明必须是当前阶段的实话（只读、归档属下一里程碑），
        // 而不能留着「深扫落地后展示可归档预计释放空间」那种对 M2 的预告。
        let message = WorkspaceSection.overview.placeholderMessage

        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains("预计释放"), "M2 不做压缩节省 / 搬迁腾出的估算（PRD §9 的范围切分）")
        XCTAssertTrue(message.contains("下一个里程碑"))
    }

    func test占位文案不承诺本阶段做不到的事() {
        // 概览 / 归档 / 已归档 / 设置都还没做，文案必须说清楚「还不可用」。
        for section in WorkspaceSection.allCases where !section.isImplemented {
            XCTAssertFalse(
                section.placeholderMessage.isEmpty,
                "\(section.id) 的占位文案不能为空，也不能承诺任何尚未实现的能力"
            )
        }
    }

    func test默认选择与分栏集合一致() {
        XCTAssertTrue(WorkspaceSection.allCases.contains(WorkspaceShellModel.defaultSelection))
    }
}
