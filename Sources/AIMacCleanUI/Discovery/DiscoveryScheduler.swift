import Foundation

/// 「重新扫描」跑在哪条线程上（issue #21）。
///
/// 一次发现要遍历规则声明的工具根、读会话文件头，本机实测约 **3 秒**。这段工作原先
/// **同步跑在调用线程（主线程）上**，于是用户点一下「重新扫描」，窗口就卡住转菊花，
/// 还会误以为应用死了——扫描再快也不该挡住界面。
///
/// 因此把「扫描」与「更新界面状态」分开成两个可注入的调度点：
/// 生产用后台队列扫描、回主线程更新；测试用同步实现，断言保持确定性。
public struct DiscoveryScheduler {

    /// 把「扫描」这段工作放到哪条线程执行。
    public let runScan: (@escaping () -> Void) -> Void

    /// 把「更新界面状态」这段工作放回主线程执行。
    public let runOnMain: (@escaping () -> Void) -> Void

    public init(
        runScan: @escaping (@escaping () -> Void) -> Void,
        runOnMain: @escaping (@escaping () -> Void) -> Void
    ) {
        self.runScan = runScan
        self.runOnMain = runOnMain
    }

    /// 同步执行：`load()` 返回时状态已经更新完毕（测试与确定性场景用）。
    public static let immediate = DiscoveryScheduler(
        runScan: { $0() },
        runOnMain: { $0() }
    )

    /// 后台扫描 + 回主线程更新（生产用）。
    ///
    /// 扫描用 `userInitiated`：它是用户点了按钮才发生的、用户正在等的事。
    public static func background(
        queue: DispatchQueue = .global(qos: .userInitiated)
    ) -> DiscoveryScheduler {
        DiscoveryScheduler(
            runScan: { work in queue.async(execute: work) },
            runOnMain: { work in DispatchQueue.main.async(execute: work) }
        )
    }
}
