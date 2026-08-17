//
//  main.swift
//  tools/wa-spike — P0 可行性尖刺：Mac 包壳 .app 的 Wi-Fi Aware 能力实测
//
//  关键约束：必须包成 .app（带 WiFiAwareServices 的 Info.plist）运行，
//  裸 CLI 无 Info.plist，WAPublishableService.allServices 恒为空。
//
//  尖刺结论（2026-08-17，Xcode 26.6 / macOS 26.6.1）：**编译期即失败**——
//  SDK 中 WiFiAware 全符号 @available(macOS, unavailable)，且系统框架为空壳。
//  WA 通道终止，见 docs/decisions.md ADR-012。本文件保留作复现/复测入口：
//  未来 SDK 开放 macOS 后，run.sh 编译通过即推翻信号。
//

import Foundation
import WiFiAware

// ① 能力探测：硬件/系统是否支持 Wi-Fi Aware
let features = WACapabilities.supportedFeatures
print("[spike] supportedFeatures = \(features)")
print("[spike] contains(.wifiAware) = \(features.contains(.wifiAware))")

// ② Info.plist 服务声明确认可读：_aimphone-wa._tcp 须在 WiFiAwareServices 字典里
let pubKeys = WAPublishableService.allServices.keys.sorted()
print("[spike] publishable services = \(pubKeys)")
if let s = WAPublishableService.allServices["_aimphone-wa._tcp"] {
    print("[spike] publishable _aimphone-wa._tcp OK: \(s)")
} else {
    print("[spike] FAIL: _aimphone-wa._tcp 不在可发布服务表（Info.plist 声明未生效）")
}

let subKeys = WASubscribableService.allServices.keys.sorted()
print("[spike] subscribable services = \(subKeys)")
print("[spike] subscribable _aimphone-wa._tcp = \(WASubscribableService.allServices["_aimphone-wa._tcp"] != nil)")
