import Foundation

import AIMacCleanDomain

/// 一个**只记写、不记读**的文件系统替身（issue #23 的零写入断言）。
///
/// 「只展示、不动」是深扫对用户的核心承诺（PRD §5.1、§2.3）。光断言「扫描结果里没有
/// 多出文件」证明不了它——那只说明*这次*没多，证明不了扫描过程**从未试过**写。
/// 于是写入口由 `WriteRecordingDiscoveryFileSystem` 基类逐笔记账，这里只是把它
/// 直接交给深扫用：一次扫描跑完，`writeAttempts` 必须为空。
///
/// 与 `RecordingDiscoveryFileSystem` 的分工：那个记「碰了哪里」（范围断言），
/// 这个记「动了什么」（零写入断言）。两者可以叠在同一棵夹具树上。
final class AuditorFileSystem: WriteRecordingDiscoveryFileSystem, @unchecked Sendable {}
