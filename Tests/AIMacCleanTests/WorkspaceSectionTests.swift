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

    func test默认停在唯一已经做出来的分栏() {
        // issue #16：概览页要到里程碑 2 才有真实内容，一开就停在占位页没有意义。
        // 断言的是「默认落在已实现的那一页」，而不是把某个 id 写死。
        XCTAssertEqual(WorkspaceShellModel.defaultSelection, .discovery)
        XCTAssertTrue(WorkspaceShellModel.defaultSelection.isImplemented)
    }

    func test只有发现与确认是已实现的分栏() {
        XCTAssertEqual(
            WorkspaceSection.allCases.filter(\.isImplemented),
            [.discovery],
            "issue #16 的范围里只有这一页是真实页面"
        )
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
