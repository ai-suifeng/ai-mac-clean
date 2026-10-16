import XCTest

import AIMacCleanDomain

/// 四类的**展示顺序**（PRD §5.1 的表格行顺序）。
///
/// 以前它是 `allCases`——顺序对只是碰巧因为枚举声明顺序正好是 PRD 的顺序。
/// 现在顺序是显式写出的常量，这组用例把它钉在 PRD §5.1 的序列上：
/// 以后谁重排 `DataCategory` 的枚举声明，这里的断言会先红，而不是界面悄悄换序。
final class DataCategoryPresentationTests: XCTestCase {

    func test展示顺序是PRD五点一的表格顺序() {
        XCTAssertEqual(
            DataCategory.displayOrder.map(\.rawValue),
            ["archivableSession", "cacheAndLog", "protected", "uncertain"],
            "PRD §5.1 表格行顺序：可归档会话 / 缓存与日志 / 受保护 / 不确定"
        )
    }

    func test展示顺序正好覆盖四类且不重复() {
        let order = DataCategory.displayOrder
        XCTAssertEqual(order.count, DataCategory.allCases.count, "四类一个不多一个不少")
        XCTAssertEqual(Set(order), Set(DataCategory.allCases), "每个类别都要出现在展示顺序里")
    }
}
