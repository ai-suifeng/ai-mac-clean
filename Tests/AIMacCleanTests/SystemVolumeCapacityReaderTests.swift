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
}
