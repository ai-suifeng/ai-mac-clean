import XCTest

@testable import AIMacCleanDomain

/// Seam B：`SystemVolumeCapacityReader` 是「真实系统读数 → 容量状态」的翻译层（ticket #24）。
///
/// 读数来源可注入，所以这些测试**不依赖本机磁盘实况**：给什么读数就断言什么状态。
/// 另一条同样重要的断言是「只问了调用方给的那一个路径」——注入点同时充当记录器，
/// 把「不枚举通用位置」（#18/#19 的纪律）从承诺变成可测的事实。
final class SystemVolumeCapacityReaderTests: XCTestCase {

    func test优先采用重要用途可用空间并只读调用方给的路径() {
        var readPaths: [String] = []
        let reader = SystemVolumeCapacityReader { path in
            readPaths.append(path)
            return SystemVolumeCapacityReader.Values(
                // 普通可用空间故意给一个更大的数：重要用途可用量才是本应用要显示的那个。
                availableForImportantUsage: 1_073_741_824,
                available: 5_368_709_120,
                total: 12 * 1024 * 1024 * 1024
            )
        }

        let capacity = reader.capacity(ofVolumeContaining: "/tmp/amc-tool-root")

        XCTAssertEqual(
            capacity,
            .measured(availableBytes: 1_073_741_824, totalBytes: 12 * 1024 * 1024 * 1024)
        )
        XCTAssertEqual(capacity.availableText, "1 GB")
        XCTAssertEqual(readPaths, ["/tmp/amc-tool-root"])
    }

    func test重要用途读数缺失时回退到普通可用空间() {
        let reader = SystemVolumeCapacityReader { _ in
            .init(
                availableForImportantUsage: nil,
                available: 2_147_483_648,
                total: 12 * 1024 * 1024 * 1024
            )
        }

        XCTAssertEqual(
            reader.capacity(ofVolumeContaining: "/tmp/amc-tool-root"),
            .measured(availableBytes: 2_147_483_648, totalBytes: 12 * 1024 * 1024 * 1024)
        )
    }

    func test没有可用容量数字时给出未知而不是零() {
        // 两个可用量都没有，以及总量没有：都只能算未知。
        // 退化成 0 的话，用户会看到「剩余 0 B」——那是盘满的意思，是假消息。
        let availableMissing = SystemVolumeCapacityReader { _ in
            .init(availableForImportantUsage: nil, available: nil, total: 12 * 1024 * 1024 * 1024)
        }
        let totalMissing = SystemVolumeCapacityReader { _ in
            .init(availableForImportantUsage: 1_073_741_824, available: nil, total: nil)
        }

        XCTAssertEqual(
            availableMissing.capacity(ofVolumeContaining: "/tmp/amc-tool-root"),
            .unknown(.capacityNotReported)
        )
        XCTAssertEqual(
            totalMissing.capacity(ofVolumeContaining: "/tmp/amc-tool-root"),
            .unknown(.capacityNotReported)
        )
    }

    func test不可展示的容量数字给出未知而不是零() {
        // 负的可用量不是可展示的体积（`ByteSizeFormatter` 会把它按 0 呈现），
        // 总量为 0 也不是一个真的卷：这两种都当未知，绝不显示 0 B。
        let negativeAvailable = SystemVolumeCapacityReader { _ in
            .init(availableForImportantUsage: -1, available: nil, total: 12 * 1024 * 1024 * 1024)
        }
        let zeroTotal = SystemVolumeCapacityReader { _ in
            .init(availableForImportantUsage: 1_073_741_824, available: nil, total: 0)
        }

        XCTAssertEqual(
            negativeAvailable.capacity(ofVolumeContaining: "/tmp/amc-tool-root"),
            .unknown(.capacityNotReported)
        )
        XCTAssertEqual(
            zeroTotal.capacity(ofVolumeContaining: "/tmp/amc-tool-root"),
            .unknown(.capacityNotReported)
        )
    }

    func test路径读不到时给出未知而不是崩溃() {
        struct ReadFailure: Error {}

        let reader = SystemVolumeCapacityReader { _ in throw ReadFailure() }

        XCTAssertEqual(
            reader.capacity(ofVolumeContaining: "/tmp/amc-tool-root"),
            .unknown(.volumeUnreadable)
        )
    }
}
