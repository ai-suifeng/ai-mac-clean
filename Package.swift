// swift-tools-version:5.9
// M1 骨架（issue #8）：按 PRD §10 建立 UI / Domain / Rules / Core 四层。
// 硬性约束：macOS 13 部署目标、Swift 5.9+、零第三方依赖。

import PackageDescription

let package = Package(
    name: "ai-mac-clean",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AIMacCleanApp", targets: ["AIMacCleanApp"])
    ],
    dependencies: [
        // 零第三方依赖（PRD §10 / spec #7 技术栈）。
    ],
    targets: [
        // 平台无关的基础设施：日志、错误类型、路径工具、字节数格式化入口。
        .target(name: "AIMacCleanCore"),

        // 声明式规则模型、规则加载、规则集准入（保护单调性）。内容见 issue #10 / #11。
        // `BundledRules/` 里的规则文件随包分发：新增一个已知工具 = 新增一个规则文件，
        // 不改代码（issue #15、spec #7 User Story 20）。
        .target(
            name: "AIMacCleanRules",
            dependencies: ["AIMacCleanCore"],
            resources: [.copy("BundledRules")]
        ),

        // 工具、候选、置信度、确认记录等领域模型与应用服务接口。内容见 issue #12 / #13。
        .target(name: "AIMacCleanDomain", dependencies: ["AIMacCleanRules", "AIMacCleanCore"]),

        // SwiftUI 视图。内容见 issue #16。
        .target(name: "AIMacCleanUI", dependencies: ["AIMacCleanDomain"]),

        // 可执行入口（@main）。
        .executableTarget(name: "AIMacCleanApp", dependencies: ["AIMacCleanUI"]),

        // 测试安全护栏内核（issue #14）：装载时给测试进程套上禁止访问真实 AI 工具
        // 数据目录的内核沙箱，并提供纯字面路径判定。C 目标——SwiftPM 不支持同一目标内混编。
        // 只被测试目标依赖，不进产品二进制。
        .target(name: "AIMacCleanPathGuard"),

        // 测试目标与被测模块同包，可访问全部层（issue #8 验收）。
        .testTarget(
            name: "AIMacCleanTests",
            dependencies: [
                "AIMacCleanPathGuard",
                "AIMacCleanCore",
                "AIMacCleanRules",
                "AIMacCleanDomain",
                "AIMacCleanUI",
            ]
        ),
    ]
)
