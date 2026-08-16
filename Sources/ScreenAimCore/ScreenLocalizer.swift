//
//  ScreenLocalizer.swift
//  ScreenAimCore — 检测 → 单应映射编排层：帧中心（瞄准点）→ 屏幕坐标
//
//  与 Mac 端 ScreenSampler 同语义：screenCornerMap 填定位码的屏幕点坐标
//  （左上原点），localize 输出帧中心在该坐标系下的映射点。
//  冗余标记模式（ADR-007）：映射表与检出标记匹配 ≥4 对即求解（RANSAC 剔除离群）。
//  线程约定：非线程安全，调用方需在串行队列使用。
//

import Foundation
import CoreGraphics

public struct LocalizationResult {
    /// 本帧检出的定位码（帧像素坐标）
    public let markers: [DetectedMarker]
    /// 帧中心映射到屏幕坐标；匹配标记 <4 或单应求解失败时为 nil
    public let aim: CGPoint?

    public init(markers: [DetectedMarker], aim: CGPoint?) {
        self.markers = markers
        self.aim = aim
    }
}

public final class ScreenLocalizer {
    /// 定位码 id → 屏幕点坐标（左上角原点）。≥4 项即可做映射（8 标记冗余，ADR-007）
    public var screenCornerMap: [Int: CGPoint] = [:]
    public let detector = ArucoDetector()

    public init() {}

    /// 处理一帧紧凑/带 padding 的 BGRA 数据
    public func localize(bgra: UnsafeRawPointer, width w: Int, height h: Int,
                         bytesPerRow: Int) -> LocalizationResult {
        let markers = detector.detect(bgra: bgra, width: w, height: h, bytesPerRow: bytesPerRow)
        guard screenCornerMap.count >= 4 else {
            return LocalizationResult(markers: markers, aim: nil)
        }
        var src: [CGPoint] = []
        var dst: [CGPoint] = []
        for m in markers {
            guard let screenPt = screenCornerMap[m.id] else { continue }
            src.append(m.center)
            dst.append(screenPt)
        }
        // 匹配 ≥4 对即 RANSAC 求解：任一角被遮挡/掉检仍有输出（ADR-007）
        guard src.count >= 4,
              let homography = Homography(ransacSrc: src, dst: dst) else {
            return LocalizationResult(markers: markers, aim: nil)
        }
        // 帧中心 = 瞄准点；结果单位与 screenCornerMap 一致
        let aim = homography.map(CGPoint(x: w / 2, y: h / 2))
        return LocalizationResult(markers: markers, aim: aim)
    }
}
