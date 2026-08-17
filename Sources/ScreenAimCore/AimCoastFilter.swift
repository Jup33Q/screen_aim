//
//  AimCoastFilter.swift
//  ScreenAimCore — 瞄准点二维输出滤波：One Euro 消抖 + 断帧滑行（速度衰减外推），双端共用
//
//  关键约束：非线程安全，与 ScreenLocalizer 同在调用方串行队列使用；
//  时间戳单位秒（任意单调时钟），必须单调递增
//

import Foundation
import CoreGraphics

/// 瞄准点输出滤波 + 断帧滑行的统一实现（WP1.2 / WP3.2 共用同一机制，见 ADR-013）。
///
/// 双端各持一个实例，禁止两处各写一份滑行逻辑：
/// - iPhone `ScreenLocalizer.aimFilter`：识别段，对 15Hz 原始识别噪声强消抖；
/// - Mac `Calibrator.dotFilter`：显示段，对 15Hz 上报做插值平滑 + 断流滑行。
///
/// 滑行语义（无瞄准样本帧）：按 One Euro 的最近低通速度外推，速度按
/// `coastHalfLife` 半衰期指数衰减（手停下时白点不继续冲），最多 `maxCoastFrames`
/// 帧，超出返回 nil（调用方隐藏白点）。外推样本回灌低通，识别恢复时输出平滑接回。
/// NOTE: WP1.2 方案原文的"沿用上一变换重投影"与本机制等价——帧中心在帧像素系
/// 恒为 (w/2, h/2)，旧变换重投影每帧输出同一点，正是速度为零的滑行特例。
public final class AimCoastFilter {

    /// 滤波/滑行参数集。改字段即生效（didSet 透传内部 One Euro）
    public struct Params: Equatable {
        /// One Euro 静止截止频率（Hz）：↓ 静止更稳但慢移拖，↑ 慢速抖动透传
        public var minCutoff = 1.0
        /// One Euro 速度系数：↑ 快速移动跟手但高速段透抖，↓ 横扫变"肉"
        public var beta = 0.5
        /// 速度估计截止频率（Hz），一般不动
        public var dCutoff = 1.0
        /// 断帧滑行预算（帧）：0 = 一丢就隐（WP1 前现状）；15Hz 下 5 帧 ≈ 330ms，
        /// 覆盖实测中位 2 帧的瞬时掉检段（2026-08-17 四会话统计，见方案 §0）
        public var maxCoastFrames = 5
        /// 滑行速度衰减半衰期（秒）：≈100ms，手真实停下时白点 2–3 帧内刹住
        public var coastHalfLife = 0.1

        public init() {}
    }

    public var params = Params() {
        didSet { pushParams() }
    }

    private var fx = OneEuroFilter(), fy = OneEuroFilter()
    private var lastOut: CGPoint?          // 最近输出（滑行外推起点）
    private var lastT: Double?
    private var coastVel = (0.0, 0.0)      // 进入滑行时快照的低通速度，逐帧衰减
    private var coastCount = 0             // 当前连续滑行帧数

    public init(params: Params = Params()) {
        self.params = params
        pushParams()
    }

    /// 送入一帧原始瞄准样本。
    /// - Parameters:
    ///   - raw: 本帧几何求解的瞄准点；nil = 本帧无解（检出不足/护栏拒绝），走滑行
    ///   - t: 单调时间戳（秒）
    /// - Returns: 输出点 + 是否滑行帧；滑行预算耗尽（或滤波器尚未初始化）返回 nil
    @discardableResult
    public func update(raw: CGPoint?, at t: Double) -> (point: CGPoint, isCoast: Bool)? {
        if let raw {
            coastCount = 0
            let out = CGPoint(x: fx.filter(raw.x, at: t), y: fy.filter(raw.y, at: t))
            lastOut = out
            lastT = t
            // 快照当前低通速度作为滑行初速：低通后的速度不含单帧识别噪声
            coastVel = (fx.velocity, fy.velocity)
            return (out, false)
        }
        // 断帧滑行：位置按衰减速度外推，外推样本回灌低通保持状态连续
        guard coastCount < params.maxCoastFrames,
              let prev = lastOut, let t0 = lastT else { return nil }
        coastCount += 1
        let dt = max(t - t0, 1e-3)
        let decay = pow(0.5, dt / params.coastHalfLife)
        coastVel = (coastVel.0 * decay, coastVel.1 * decay)
        let pred = CGPoint(x: prev.x + coastVel.0 * dt, y: prev.y + coastVel.1 * dt)
        let out = CGPoint(x: fx.filter(pred.x, at: t), y: fy.filter(pred.y, at: t))
        lastOut = out
        lastT = t
        return (out, true)
    }

    /// 回到未初始化状态；下一帧样本直接透传并作为新基线
    public func reset() {
        fx.reset()
        fy.reset()
        lastOut = nil
        lastT = nil
        coastVel = (0, 0)
        coastCount = 0
    }

    private func pushParams() {
        fx.minCutoff = params.minCutoff; fy.minCutoff = params.minCutoff
        fx.beta = params.beta; fy.beta = params.beta
        fx.dCutoff = params.dCutoff; fy.dCutoff = params.dCutoff
    }
}
