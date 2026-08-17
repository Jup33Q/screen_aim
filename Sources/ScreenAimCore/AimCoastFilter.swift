//
//  AimCoastFilter.swift
//  ScreenAimCore — 瞄准点二维输出滤波：One Euro 消抖 + 跳变门限 + 断帧滑行，双端共用
//
//  关键约束：非线程安全，与 ScreenLocalizer 同在调用方串行队列使用；
//  时间戳单位秒（任意单调时钟），必须单调递增
//

import Foundation
import CoreGraphics

/// 瞄准点输出滤波三层增强的统一实现（WP1.2 / WP3，见 ADR-013 / ADR-014）。
///
/// 双端各持一个实例，禁止两处各写一份滑行/门限逻辑；两段参数显式分离
/// （`AimFilterPreset.phone` / `.macDisplay`），各管什么见 preset 注释：
/// - iPhone `ScreenLocalizer.aimFilter`：识别段，对 15Hz 原始识别噪声强消抖；
/// - Mac `Calibrator.dotFilter`：显示段，只做 15Hz 上报 → 显示的插值平滑 +
///   跳变门 + 滑行，不重复消抖（双段都消抖会让横扫滞后叠加）。
///
/// 三层机制（同一状态机）：
/// 1. One Euro 低通消抖（核心算法不更换，Casiez et al. 就是为人手指针场景发明的）；
/// 2. 跳变门限（WP3.1）：新样本与预测距离 > gateK × max(近期残差 σ̂, gateFloor) 时
///    本帧保持预测输出、不计入状态更新，防 RANSAC 漏网的 5–20pt 级单帧跳变甩白点；
///    滑行（含拦截帧）后首帧旁路门限——残差里是真实位移而非噪声，持续快速移动
///    最多被压 1 帧，不会压死真实横扫；
/// 3. 断帧滑行（WP1.2/WP3.2）：无样本帧按最近低通速度外推，速度按 coastHalfLife
///    半衰期指数衰减，最多 maxCoastFrames 帧，超出返回 nil（调用方隐藏白点）；
///    外推样本回灌低通，识别恢复时输出平滑接回。
/// 另提供只读接口 `displayExtrapolation(at:)`（WP-L1，ADR-015）：Mac 60Hz 显示
/// 定时器在两次上报空窗内按 coastVel 匀速死推算摆点（时距封顶 120ms），
/// 不改滤波状态，与上述三层机制正交。
/// NOTE: WP1.2 方案原文的"沿用上一变换重投影"与滑行等价——帧中心在帧像素系
/// 恒为 (w/2, h/2)，旧变换重投影每帧输出同一点，正是速度为零的滑行特例。
public final class AimCoastFilter {

    /// 滤波/门限/滑行参数集。改字段即生效（didSet 透传内部 One Euro）
    public struct Params: Equatable {
        /// One Euro 静止截止频率（Hz）：↓ 静止更稳但慢移拖，↑ 慢速抖动透传
        public var minCutoff = 1.0
        /// One Euro 速度系数：↑ 快速移动跟手但高速段透抖，↓ 横扫变"肉"
        public var beta = 0.5
        /// 速度估计截止频率（Hz），一般不动
        public var dCutoff = 1.0
        /// 跳变门限系数 k（WP3.1）：门限 = k × max(σ̂, gateFloor)；nil = 关闭（旧行为）
        public var gateK: Double? = 2.5
        /// 残差 σ̂ 下限（pt）：静止 σ 仅 0.05–0.08pt 级，无下限会把正常移动也压死；
        /// 2.0pt × k2.5 = 5pt 最小门限，恰好放行缓慢移动、拦 15pt 级跳变
        public var gateFloor = 2.0
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
    private var lastOut: CGPoint?          // 最近输出（预测/滑行外推起点）
    private var lastT: Double?
    private var coastVel = (0.0, 0.0)      // 最近被接受样本后的低通速度，滑行中逐帧衰减
    private var coastCount = 0             // 当前连续滑行帧数（含跳变门拦截帧）
    private var sigmaHat = 0.0             // 预测残差 σ 的 EWMA 估计（跳变门自适应部分）

    public init(params: Params = Params()) {
        self.params = params
        pushParams()
    }

    /// 送入一帧原始瞄准样本。
    /// - Parameters:
    ///   - raw: 本帧几何求解的瞄准点；nil = 本帧无解（检出不足/护栏拒绝），走滑行
    ///   - t: 单调时间戳（秒）
    /// - Returns: 输出点 + 是否滑行帧（跳变门拦截帧也算滑行）；滑行预算耗尽
    ///   （或滤波器尚未初始化）返回 nil
    @discardableResult
    public func update(raw: CGPoint?, at t: Double) -> (point: CGPoint, isCoast: Bool)? {
        if let raw {
            if params.gateK != nil, let prev = lastOut, let t0 = lastT {
                let dt = max(t - t0, 1e-3)
                let pred = CGPoint(x: prev.x + coastVel.0 * dt, y: prev.y + coastVel.1 * dt)
                let e = hypot(raw.x - pred.x, raw.y - pred.y)
                // 滑行（含拦截帧）后首帧旁路门限：滑行期残差包含断流/拦截期间的真实位移，
                // 不是噪声跳变；这也意味着单帧跳变恰好被拦 1 帧（拦截帧后的真实样本必然
                // 旁路接受），持续同向超门限 = 真实快速移动，最多被压 1 帧
                if let gateK = params.gateK, coastCount == 0,
                   e > gateK * max(sigmaHat, params.gateFloor) {
                    return coastStep(at: t)
                }
                // σ̂ EWMA 更新：高斯假设下 E|e| ≈ 0.8σ，换算系数 1.25；
                // 只用被接受样本更新，拦截帧的 15pt 级残差不准膨胀门限。
                // 旁路接受帧照常更新：持续快速移动时门限随真实运动量级自适应放宽
                sigmaHat = sigmaHat == 0 ? 1.25 * e : 0.9 * sigmaHat + 0.125 * e
            }
            coastCount = 0
            let out = CGPoint(x: fx.filter(raw.x, at: t), y: fy.filter(raw.y, at: t))
            lastOut = out
            lastT = t
            // 快照当前低通速度作为滑行初速：低通后的速度不含单帧识别噪声
            coastVel = (fx.velocity, fy.velocity)
            return (out, false)
        }
        return coastStep(at: t)
    }

    /// 断帧滑行：位置按衰减速度外推，外推样本回灌低通保持状态连续；
    /// 返回 nil = 滑行预算耗尽（或滤波器尚未初始化）
    private func coastStep(at t: Double) -> (point: CGPoint, isCoast: Bool)? {
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

    /// 显示外推时距上限（秒，WP-L1/ADR-015）：外推只填两次上报之间的显示空窗，
    /// 超过上限返回封顶点原地保持——网络延迟突增时防止白点持续冲过真实位置（方案 §5）
    public static let maxDisplayExtrapolation = 0.12

    /// 显示段死推算外推（WP-L1，ADR-015）：返回 t 时刻的纯外推显示位置，**只读**，
    /// 不改任何滤波状态。供 Mac 60Hz 显示定时器在两次 localAim 到达的空窗内重摆白点；
    /// 权威位置仍是 `update()` 的输出，断流滑行预算也仍只由 `update(raw: nil)`
    /// 的帧计数控制，本接口与滑行语义正交。
    ///
    /// 位置 = `lastOut + coastVel × Δt`，窗口内**不做速度衰减**：≤120ms 窗口里
    /// coastHalfLife（0.1s）衰减会把 +66ms 推进量压低 ~24%，匀速 300pt/s 时偏离
    /// 真值 ~7pt 并在每个上报间隔内制造 ~15Hz 锯齿；过冲防护由时距封顶 +
    /// 新样本到达即校正承担（方案 §5）。
    /// - Returns: 外推点（Δt 内部封顶 `maxDisplayExtrapolation`，封顶后原地保持；
    ///   时钟回拨按 Δt=0 处理）；滤波器未初始化（尚无输出或已 `reset()`）返回 nil
    public func displayExtrapolation(at t: Double) -> CGPoint? {
        guard let prev = lastOut, let t0 = lastT else { return nil }
        let dt = min(max(t - t0, 0), Self.maxDisplayExtrapolation)
        return CGPoint(x: prev.x + coastVel.0 * dt, y: prev.y + coastVel.1 * dt)
    }

    /// 回到未初始化状态；下一帧样本直接透传并作为新基线
    public func reset() {
        fx.reset()
        fy.reset()
        lastOut = nil
        lastT = nil
        coastVel = (0, 0)
        coastCount = 0
        sigmaHat = 0
    }

    private func pushParams() {
        fx.minCutoff = params.minCutoff; fy.minCutoff = params.minCutoff
        fx.beta = params.beta; fy.beta = params.beta
        fx.dCutoff = params.dCutoff; fy.dCutoff = params.dCutoff
    }
}

/// 口语化预设三档（WP3.3/3.4，逐项说明见 docs/aim-filter-tuning.md，ADR-014）。
/// 每档给双端两套参数（分层解耦，WP3.3）：
/// - `phone`（iPhone 识别段）：对 15Hz 原始识别噪声强消抖，是消抖主战场；
/// - `macDisplay`（Mac 显示段）：iPhone 已消抖，这段只做 15Hz 上报 → 显示的
///   插值平滑 + 跳变门 + 滑行，截止频率明显更高（消抖任务不重复做，
///   否则双段低通串联、横扫滞后叠加）。
public enum AimFilterPreset: String, CaseIterable, Sendable {
    /// 「稳如三脚架」：演示、精细点击
    case stable
    /// 「日常跟手」（默认）：通用
    case daily
    /// 「疾速响应」：快速拖拽、大范围甩动
    case fast

    /// iPhone 识别段参数（ScreenLocalizer.aimFilter）
    public var phone: AimCoastFilter.Params {
        var p = AimCoastFilter.Params()
        switch self {
        case .stable: p.minCutoff = 0.6; p.beta = 0.25; p.maxCoastFrames = 3; p.gateK = 1.8
        case .daily:  break   // 默认即「日常跟手」：1.0 / 0.5 / 5 帧 / k=2.5
        case .fast:   p.minCutoff = 1.6; p.beta = 1.0;  p.maxCoastFrames = 8; p.gateK = 4.0
        }
        return p
    }

    /// Mac 显示段参数（Calibrator.dotFilter）：只插值平滑，不重复消抖
    public var macDisplay: AimCoastFilter.Params {
        var p = AimCoastFilter.Params()
        switch self {
        case .stable: p.minCutoff = 1.2; p.beta = 0.5; p.maxCoastFrames = 3; p.gateK = 1.8
        case .daily:  p.minCutoff = 2.0; p.beta = 1.0; p.maxCoastFrames = 5; p.gateK = 2.5
        case .fast:   p.minCutoff = 3.0; p.beta = 2.0; p.maxCoastFrames = 8; p.gateK = 4.0
        }
        return p
    }
}
