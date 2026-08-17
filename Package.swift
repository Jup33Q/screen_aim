// swift-tools-version: 6.2
import PackageDescription

// OpenCV 来自 Homebrew: brew install opencv
// 头文件: /opt/homebrew/opt/opencv/include/opencv5
// 链接库: /opt/homebrew/opt/opencv/lib
let opencvInclude = "/opt/homebrew/opt/opencv/include/opencv5"
let opencvLib = "/opt/homebrew/opt/opencv/lib"

let package = Package(
    name: "ScreenAim",
    platforms: [
        // 传输层迁移（transport-26-plan）：TLV framer / NetworkListener 新 API 需 26+
        .macOS(.v26)
    ],
    targets: [
        // 纯 Swift 核心：ArUco(DICT_4X4_50) 检测 + 单应映射，iOS/macOS 双端共享
        //（iOS 端由 XcodeGen 直接把本目录编进 AimPhone，不经 SwiftPM）
        .target(
            name: "ScreenAimCore"
        ),
        // Objective-C++ 桥接层：把 cv::aruco / 单应映射封装成纯 ObjC API 给 Swift 用
        .target(
            name: "OpenCVBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-I", opencvInclude, "-std=c++17"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", opencvLib,
                    "-Xlinker", "-rpath", "-Xlinker", opencvLib
                ]),
                .linkedLibrary("opencv_objdetect"),
                .linkedLibrary("opencv_imgcodecs"),
                .linkedLibrary("opencv_calib"),
                .linkedLibrary("opencv_imgproc"),
                .linkedLibrary("opencv_geometry"),
                .linkedLibrary("opencv_core"),
            ]
        ),
        .executableTarget(
            name: "ScreenAim",
            dependencies: ["OpenCVBridge", "ScreenAimCore"]
        )
    ],
    // NOTE: 旧 FrameServer/CaptureServer 的 NWConnection 回调代码在 Swift 6 语言模式下
    // 触发并发检查报错；它们是 P3 拆除对象，不值得先做并发化改造。
    // 过渡期保持 v5 语言模式（tools 6.2 + macOS v26 平台门槛不受影响），
    // 新增代码（FrameServerV2 等）直接写结构化并发，不受影响。
    swiftLanguageModes: [.v5]
)
