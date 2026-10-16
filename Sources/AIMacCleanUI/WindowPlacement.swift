import AppKit
import SwiftUI

/// 窗口落点的收拢规则：把系统恢复出来的窗口框收进**用户正在用的那块屏**的可见区域。
///
/// 为什么需要它：窗口位置由 AppKit 自动保存与恢复。多屏环境下（尤其是接了虚拟屏 /
/// 副屏、或显示布局变过之后再打开），恢复出来的位置可能落在**另一块屏幕**上，甚至落在
/// 当前没有任何一块屏幕能显示的地方——进程在跑、窗口也「存在」，用户却什么都看不到，
/// 只会以为应用没起来。本机实测就撞上了这一条：窗口被恢复到虚拟屏上，主屏上什么都没有。
///
/// 判定与收拢都是纯函数，边界可以逐条断言，不需要真的开窗口。
public enum WindowPlacement {

    /// 至少要有这么多宽高留在**用户正在用的那块屏**的可见区域内，才算「用户看得见」。
    ///
    /// 取的是**标题栏**的量级：只要标题栏能露出来，用户就能拖动窗口，不必替他搬家。
    public static let minimumVisibleSize = CGSize(width: 120, height: 28)

    /// 返回应采用的窗口框。
    ///
    /// - `frame`：系统恢复出来的窗口框。
    /// - `visibleFrames`：各屏幕的可见区域（不含菜单栏与 Dock）。
    /// - `preferred`：用户正在用的那块屏（`NSScreen.main`）的可见区域。
    /// - 已经在 `preferred` 上露得够多时**原样返回**——不打扰用户的窗口摆放。
    /// - 否则居中对齐到 `preferred`，保持原尺寸（尺寸超出时收进可见区域）。
    /// - 没有 `preferred` 时退到「任何一块屏幕看得见就保留」，`visibleFrames` 也为空则原样返回。
    public static func visibleFrame(
        for frame: CGRect,
        visibleFrames: [CGRect],
        preferred: CGRect?
    ) -> CGRect {
        guard let target = preferred ?? visibleFrames.first else { return frame }

        // 有 preferred 时只认它：窗口在别的屏上「看得见」不算——用户看的是这一块。
        if preferred != nil, hasEnoughVisibleArea(frame, in: target) { return frame }
        // 没有 preferred 时，任何一块屏幕看得见就保留。
        if preferred == nil, visibleFrames.contains(where: { hasEnoughVisibleArea(frame, in: $0) }) {
            return frame
        }

        let size = CGSize(
            width: min(frame.width, target.width),
            height: min(frame.height, target.height)
        )
        return CGRect(
            x: target.midX - size.width / 2,
            y: target.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// 窗口框与某块屏幕可见区域的重叠，是否够用户看见标题栏。
    private static func hasEnoughVisibleArea(_ frame: CGRect, in visible: CGRect) -> Bool {
        let overlap = frame.intersection(visible)
        guard !overlap.isNull else { return false }
        return overlap.width >= minimumVisibleSize.width
            && overlap.height >= minimumVisibleSize.height
    }
}

/// 把上面那条规则挂到真实的 `NSWindow` 上：出现时检查一次，不可见就搬回主屏并居中。
///
/// 只在窗口**第一次出现**时执行，之后不再干涉用户的拖动与缩放。
struct WindowFrameGuard: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let target = WindowPlacement.visibleFrame(
                for: window.frame,
                visibleFrames: NSScreen.screens.map(\.visibleFrame),
                preferred: NSScreen.main?.visibleFrame
            )
            guard target != window.frame else { return }
            window.setFrame(target, display: true)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
