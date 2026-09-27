// swift-tools-version: 5.9
//
// diarize-helper（C-1 原型逐字节搬进主树，见同目录 INTEGRATION.md）
//
// 与 C-1 冻结版**只有本文件的注释不同**，代码一个字没动——核查办法：
//   diff -r --exclude=.build --exclude=.git --exclude=INTEGRATION.md \
//       ~/ClassroomTranscriber-spike/C-helper Vendor/DiarizeHelper
// 输出只有本文件的两处注释。
//
// 说明：FluidAudio 的 manifest 是 swift-tools-version 6.0，本包用 5.9 是为了
// 让我们的 target 落在 Swift 5 语言模式，减少与 FluidAudio 的 Sendable/并发检查摩擦。
// 兼容 Swift 6.x 工具链。

import PackageDescription

let package = Package(
    name: "diarize-helper",
    platforms: [
        // FluidAudio 的离线 diarizer 是 @available(macOS 14, iOS 17)，
        // 主 App 也是 macOS。这里钉 14。
        .macOS(.v14)
    ],
    products: [
        .executable(name: "diarize-helper", targets: ["DiarizeHelper"])
    ],
    dependencies: [
        // `../FluidAudio` 在主树里是 git submodule，钉在 commit 5c51c5c
        // （与 C-1 验过的那个 commit 同一个，上游 URL 见 .gitmodules）。
        // 这里**刻意用 path 而不是 url 依赖**：submodule 的检出、钉版、完整性
        // 由 build.sh 一处把关并在缺的时候响亮失败；改成 url 依赖会让 SwiftPM
        // 自己去 clone，那个过程不钉 commit、也不归 build.sh 管。
        .package(path: "../FluidAudio")
    ],
    targets: [
        .executableTarget(
            name: "DiarizeHelper",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/DiarizeHelper"
        )
    ]
)
