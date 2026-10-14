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

    func test默认停在概览页() {
        XCTAssertEqual(WorkspaceShellModel.defaultSelection, .overview)
    }

    func test默认选择与分栏集合一致() {
        XCTAssertTrue(WorkspaceSection.allCases.contains(WorkspaceShellModel.defaultSelection))
    }
}
