import XCTest

@testable import AIMacCleanDomain

/// Seam A：`VolumeCapacity` 是「某个路径所在卷剩多少、一共多少」的状态值（ticket #24）。
///
/// 期望值是钉死的字面量，与 `ByteSizeFormatterTests` 同一批口径（PRD §14.1 实测），
/// 不是按实现复算的：绕开 `ByteSizeFormatter` 自己拼数字就会红。
final class VolumeCapacityTests: XCTestCase {

    func test已知容量按统一体积格式给出剩余与总量文本() {
        let capacity = VolumeCapacity.measured(
            availableBytes: 7_838_315_315,
            totalBytes: 12 * 1024 * 1024 * 1024
        )

        XCTAssertEqual(capacity.availableText, "7.3 GB")
        XCTAssertEqual(capacity.totalText, "12 GB")
    }
}
