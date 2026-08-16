// swift-tools-version: 5.10
import PackageDescription

// OpenCV 来自 Homebrew: brew install opencv
// 头文件: /opt/homebrew/opt/opencv/include/opencv5
// 链接库: /opt/homebrew/opt/opencv/lib
let opencvInclude = "/opt/homebrew/opt/opencv/include/opencv5"
let opencvLib = "/opt/homebrew/opt/opencv/lib"

let package = Package(
    name: "ScreenAim",
    platforms: [
        .macOS(.v14)
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
    ]
)
