import AppKit
import XCTest

import AIMacCleanUI

/// issue #20：恢复出来的窗口位置不可见时，应收拢回可见屏幕。
///
/// 失效模式很具体：多屏（含虚拟屏）环境下 AppKit 把新窗口放到了用户没在看的那块屏上，
/// 进程在跑、窗口存在，用户却什么都看不到，只会以为应用没启动。判定是纯函数，逐条断言。
final class WindowPlacementTests: XCTestCase {

    private let mainScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// 一块位于主屏上方、横向偏左的虚拟屏（本机真实布局）。
    private let virtualScreen = CGRect(x: -1132, y: 982, width: 1920, height: 1080)

    func test窗口已完整落在某块屏幕时原样返回() {
        let frame = CGRect(x: 150, y: 150, width: 900, height: 560)

        let result = WindowPlacement.visibleFrame(
            for: frame,
            visibleFrames: [mainScreen],
            preferred: mainScreen
        )

        XCTAssertEqual(result, frame)
    }

    func test窗口落在用户没在看的虚拟屏上时搬到主屏居中() {
        // 恢复出来的位置在虚拟屏里——它「有屏幕可显示」，但用户看的是主屏。
        let frame = CGRect(x: -253, y: 1091, width: 900, height: 560)

        let result = WindowPlacement.visibleFrame(
            for: frame,
            visibleFrames: [mainScreen, virtualScreen],
            preferred: mainScreen
        )

        XCTAssertEqual(result.width, 900)
        XCTAssertEqual(result.height, 560)
        XCTAssertEqual(result.midX, mainScreen.midX, accuracy: 0.01)
        XCTAssertEqual(result.midY, mainScreen.midY, accuracy: 0.01)
    }

    func test窗口完全在所有屏幕之外时搬到主屏居中() {
        let frame = CGRect(x: -3000, y: -3000, width: 900, height: 560)

        let result = WindowPlacement.visibleFrame(
            for: frame,
            visibleFrames: [mainScreen],
            preferred: mainScreen
        )

        XCTAssertTrue(mainScreen.contains(result), "收拢后应当完整落在主屏可见区域内：\(result)")
    }

    func test只在主屏露出一条边时收拢到主屏居中() {
        // 主屏上只剩不到标题栏宽度的一条边——拖不动，等于看不见。
        let frame = CGRect(x: -800, y: 900, width: 900, height: 560)

        let result = WindowPlacement.visibleFrame(
            for: frame,
            visibleFrames: [mainScreen],
            preferred: mainScreen
        )

        XCTAssertEqual(result.midX, mainScreen.midX, accuracy: 0.01)
        XCTAssertEqual(result.midY, mainScreen.midY, accuracy: 0.01)
    }

    func test标题栏够得着时不打扰用户的摆放() {
        // 主屏上露出超过标题栏宽度，用户可以自己拖回来。
        let frame = CGRect(x: -700, y: 900, width: 900, height: 560)

        let result = WindowPlacement.visibleFrame(
            for: frame,
            visibleFrames: [mainScreen],
            preferred: mainScreen
        )

        XCTAssertEqual(result, frame, "只要标题栏看得见、拖得动，就不该替用户搬家")
    }

    func test窗口比屏幕还大时收进可见区域() {
        let frame = CGRect(x: -5000, y: -5000, width: 4000, height: 3000)

        let result = WindowPlacement.visibleFrame(
            for: frame,
            visibleFrames: [mainScreen],
            preferred: mainScreen
        )

        XCTAssertEqual(result.width, mainScreen.width)
        XCTAssertEqual(result.height, mainScreen.height)
        XCTAssertEqual(result, mainScreen)
    }

    func test没有可用屏幕时不做无依据的改动() {
        let frame = CGRect(x: -253, y: 1091, width: 900, height: 560)

        let result = WindowPlacement.visibleFrame(for: frame, visibleFrames: [], preferred: nil)

        XCTAssertEqual(result, frame)
    }

    func test没有主屏信息时落在第一块可见屏幕() {
        let frame = CGRect(x: -3000, y: -3000, width: 900, height: 560)

        let result = WindowPlacement.visibleFrame(
            for: frame,
            visibleFrames: [virtualScreen],
            preferred: nil
        )

        XCTAssertEqual(result.midX, virtualScreen.midX, accuracy: 0.01)
        XCTAssertEqual(result.midY, virtualScreen.midY, accuracy: 0.01)
    }
}
