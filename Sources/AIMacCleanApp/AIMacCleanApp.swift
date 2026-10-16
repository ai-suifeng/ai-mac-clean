import SwiftUI

import AIMacCleanUI

/// 可执行入口：只负责把 UI 层的外壳挂到窗口上。
///
/// 签名与公证、DMG 打包属于里程碑 6（PRD §12），本票不涉及。
@main
struct AIMacCleanApp: App {
    var body: some Scene {
        WindowGroup {
            WorkspaceShellView()
        }
        .defaultSize(width: 900, height: 560)
    }
}
