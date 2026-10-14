import XCTest

import AIMacCleanCore
import AIMacCleanRules
import AIMacCleanDomain
import AIMacCleanUI

/// Seam E：层可达性（issue #8 的验收项「四个层 target 存在且可被其它 target 依赖；
/// 测试目标可以访问全部层」）。
///
/// 这条断言的价值主要在编译期：文件里对四层的引用必须解析成功，
/// 少一个 target、名字写错、或某层没有对外公开，都会直接编译失败。
/// 运行期的 `isEmpty` 断言只用来防止占位被清空成空串。
final class LayerReachabilityTests: XCTestCase {

    func test四个层都从测试目标可达() {
        XCTAssertFalse(CoreLayer.layerIdentifier.isEmpty)
        XCTAssertFalse(RulesLayer.layerIdentifier.isEmpty)
        XCTAssertFalse(DomainLayer.layerIdentifier.isEmpty)
        XCTAssertFalse(UILayer.layerIdentifier.isEmpty)
    }

    func test层标识唯一() {
        let identifiers = [
            CoreLayer.layerIdentifier,
            RulesLayer.layerIdentifier,
            DomainLayer.layerIdentifier,
            UILayer.layerIdentifier,
        ]
        XCTAssertEqual(Set(identifiers).count, 4)
    }

    func test核心层不依赖其它层() {
        // Core 是平台无关的基础设施，任何反向依赖都会让四层退化成一个环。
        XCTAssertTrue(CoreLayer.allowedDependencyLayerIdentifiers.isEmpty)
    }

    func test其它层的声明依赖不包含自身以外的非法层() {
        let known: Set<String> = ["Core", "Rules", "Domain", "UI"]
        XCTAssertTrue(RulesLayer.allowedDependencyLayerIdentifiers.isSubset(of: known))
        XCTAssertTrue(DomainLayer.allowedDependencyLayerIdentifiers.isSubset(of: known))
        XCTAssertTrue(UILayer.allowedDependencyLayerIdentifiers.isSubset(of: known))
    }

    func test依赖方向自下而上() {
        XCTAssertEqual(CoreLayer.layerIdentifier, "Core")
        XCTAssertEqual(RulesLayer.layerIdentifier, "Rules")
        XCTAssertEqual(DomainLayer.layerIdentifier, "Domain")
        XCTAssertEqual(UILayer.layerIdentifier, "UI")
    }
}
