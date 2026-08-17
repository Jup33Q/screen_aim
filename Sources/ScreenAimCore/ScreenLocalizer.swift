//
//  ScreenLocalizer.swift
//  ScreenAimCore — 检测 → 几何求解（单应/仿射兜底）→ 滤波/滑行输出编排层：帧中心（瞄准点）→ 屏幕坐标
//
//  与 Mac 端 ScreenSampler 同语义：screenCornerMap 填定位码的屏幕点坐标
//  （左上原点），localize 输出帧中心在该坐标系下的映射点。
//  冗余标记模式（ADR-007）：匹配 ≥4 对走 RANSAC 单应；恰好 3 对退仿射兜底 +
//  凸包护栏（WP1.1，ADR-013）；检出不足时断帧滑行外推（WP1.2）。
//  线程约定：非线程安全，调用方需在串行队列使用。
//

import Foundation
import CoreGraphics

/// 瞄准点输出等级（WP1，协议只加不删：localAim 可选字段 `quality`，旧端忽略）。
/// 离线分析用：区分真实几何解与外推输出，统计三点簇帧转化率
public enum AimQuality: String, Sendable {
    case homography   // ≥4 对匹配，RANSAC 单应
    case affine       // 恰好 3 对，仿射兜底且通过凸包发散护栏
    case coast        // 断帧滑行外推（无有效几何解，AimCoastFilter 速度衰减外推）
}

public struct LocalizationResult {
    /// 本帧检出的定位码（帧像素坐标）
    public let markers: [DetectedMarker]
    /// 帧中心映射到屏幕坐标；匹配 <3 且滑行预算耗尽、或求解失败时为 nil
    public let aim: CGPoint?
    /// 输出等级；aim 非空时非 nil，旧调用方可忽略
    public let quality: AimQuality?

    public init(markers: [DetectedMarker], aim: CGPoint?, quality: AimQuality? = nil) {
        self.markers = markers
        self.aim = aim
        self.quality = quality
    }
}

public final class ScreenLocalizer {
    /// 定位码 id → 屏幕点坐标（左上角原点）。≥3 项即可映射（≥4 走单应，3 走仿射兜底）
    public var screenCornerMap: [Int: CGPoint] = [:]
    public let detector = ArucoDetector()
    /// 输出侧滤波 + 断帧滑行开关；基准对比时关闭（关闭后无滤波也无滑行，测原始几何解）
    public var aimFilterEnabled = true
    /// iPhone 识别段输出滤波（强消抖，对 15Hz 原始识别噪声）+ 断帧滑行（ADR-013/014）。
    /// 公开以便调参：默认 minCutoff=1.0 / beta=0.5 / 滑行 5 帧，调参指南见 docs/aim-filter-tuning.md
    public let aimFilter = AimCoastFilter()
    /// 仿射兜底发散护栏倍数：映射瞄点须在三点外接框以框心放大该倍数的范围内（WP1.1）。
    /// 仿射不能外推透视，护栏外误差发散，宁可无输出也不给误导性坐标
    public var affineGuardFactor: Double = 1.5
    private var noAimFrames = 0

    public init() {}

    /// 处理一帧紧凑/带 padding 的 BGRA 数据。
    /// - Parameter timestamp: 帧时间戳（秒，单调）。nil 取当前墙钟；
    ///   有采集时间戳（如 CMSampleBuffer PTS）时传入更准——滤波器 dt 精度直接影响消抖效果
    public func localize(bgra: UnsafeRawPointer, width w: Int, height h: Int,
                         bytesPerRow: Int, timestamp: CFAbsoluteTime? = nil) -> LocalizationResult {
        let markers = detector.detect(bgra: bgra, width: w, height: h, bytesPerRow: bytesPerRow)
        var src: [CGPoint] = []
        var dst: [CGPoint] = []
        for m in markers {
            guard let screenPt = screenCornerMap[m.id] else { continue }
            src.append(m.center)
            dst.append(screenPt)
        }
        let (aim, quality) = processMatches(src: src, dst: dst,
                                            frameCenter: CGPoint(x: w / 2, y: h / 2),
                                            timestamp: timestamp)
        return LocalizationResult(markers: markers, aim: aim, quality: quality)
    }

    /// 检测之后的完整管线：几何求解 → 输出滤波/断帧滑行。
    /// 自检/回放可绕过检测器直接注入合成匹配点（--self-test 的 WP1 场景即用此入口）。
    /// - Parameters:
    ///   - src/dst: 匹配对（帧像素 → 屏幕点坐标）
    ///   - frameCenter: 帧中心（瞄准点，帧像素坐标）
    public func processMatches(src: [CGPoint], dst: [CGPoint], frameCenter: CGPoint,
                               timestamp: CFAbsoluteTime? = nil) -> (aim: CGPoint?, quality: AimQuality?) {
        let t = timestamp ?? CFAbsoluteTimeGetCurrent()
        if let (raw, quality) = solveAim(src: src, dst: dst, frameCenter: frameCenter) {
            noAimFrames = 0
            if aimFilterEnabled {
                // 滤波输出；被跳变门拦下的帧输出滑行预测（quality 随之降 coast）
                if let out = aimFilter.update(raw: raw, at: t) {
                    return (out.point, out.isCoast ? .coast : quality)
                }
            }
            return (raw, quality)
        }
        // 断帧滑行（WP1.2/WP3.2 共用 AimCoastFilter，ADR-013）：速度衰减外推，
        // 最多 maxCoastFrames 帧（默认 5 ≈ 330ms@15Hz），覆盖实测中位 2 帧的瞬时掉检
        if aimFilterEnabled, let out = aimFilter.update(raw: nil, at: t) {
            return (out.point, .coast)
        }
        registerNoAim()
        return (nil, nil)
    }

    /// 几何求解层：≥4 对 RANSAC 单应（ADR-007）；恰好 3 对仿射兜底 + 凸包护栏（WP1.1）。
    /// 自检可绕过检测直接注入匹配点
    public func solveAim(src: [CGPoint], dst: [CGPoint],
                         frameCenter: CGPoint) -> (aim: CGPoint, quality: AimQuality)? {
        guard screenCornerMap.count >= 3 else { return nil }
        // 匹配 ≥4 对即 RANSAC 求解：任一角被遮挡/掉检仍有输出（ADR-007）
        if src.count >= 4, let homography = Homography(ransacSrc: src, dst: dst) {
            return (homography.map(frameCenter), .homography)
        }
        // 恰好 3 对：仿射兜底（WP1.1）。近距瞄角时视野只有「角标 + 相邻边中点」
        // 三点簇（方案 §0 数据），屏幕是平面，簇内仿射误差 pt 级
        if src.count == 3, let affine = AffineTransform(src: src, dst: dst) {
            let p = affine.map(frameCenter)
            // 发散护栏：仿射不能外推透视，瞄点超出三点外接框 affineGuardFactor 倍
            // 范围时误差发散，宁可无输出也不给误导性坐标（方案 §6 风险登记）
            guard withinAffineGuard(p, dst: dst) else { return nil }
            return (p, .affine)
        }
        return nil
    }

    /// 仿射护栏：瞄点须落在三点外接框以框心放大 affineGuardFactor 倍的矩形内
    private func withinAffineGuard(_ p: CGPoint, dst: [CGPoint]) -> Bool {
        let xs = dst.map(\.x), ys = dst.map(\.y)
        let cx = (xs.min()! + xs.max()!) / 2, cy = (ys.min()! + ys.max()!) / 2
        let hx = (xs.max()! - xs.min()!) / 2 * affineGuardFactor
        let hy = (ys.max()! - ys.min()!) / 2 * affineGuardFactor
        return abs(p.x - cx) <= hx && abs(p.y - cy) <= hy
    }

    /// 连续 10 帧无输出后重置滤波器：旧状态会在标记恢复后把瞄准点拖向过期位置
    private func registerNoAim() {
        noAimFrames += 1
        if noAimFrames >= 10 {
            aimFilter.reset()
            noAimFrames = 0
        }
    }
}
