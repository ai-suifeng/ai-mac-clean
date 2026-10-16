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

    func test取不到容量时不给出可展示数字() {
        // 「未知」必须能被界面识别成一个明确状态：给不出数字，就不显示数字。
        for reason in [VolumeCapacity.UnknownReason.volumeUnreadable, .capacityNotReported] {
            let capacity = VolumeCapacity.unknown(reason)
            XCTAssertNil(capacity.availableText, "\(reason) 不该给出剩余空间文本")
            XCTAssertNil(capacity.totalText, "\(reason) 不该给出总量文本")
        }
    }

    func test零字节可用是盘满而不是未知() {
        // 真正的 0 是合法读数：盘确实满了要如实说，不能被顺手归进「未知」。
        let full = VolumeCapacity.measured(availableBytes: 0, totalBytes: 1024 * 1024 * 1024)

        XCTAssertEqual(full.availableText, "0 B")
        XCTAssertNotEqual(full, .unknown(.capacityNotReported))
    }
}
