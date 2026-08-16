//
//  OneEuroFilter.swift
//  ScreenAimCore — One Euro 低通滤波器（瞄准点输出消抖），iOS/macOS 双端可用
//
//  关键约束：非线程安全，与 ScreenLocalizer 同在调用方串行队列使用；
//  时间戳单位秒（CFAbsoluteTime 或任意单调时钟），必须单调递增
//

import Foundation

/// One Euro Filter（Casiez et al. CHI 2012）：截止频率随速度自适应的一阶低通。
/// 低速时低截止强消抖，高速时高截止低延迟——瞄准点"静止不抖、横扫不拖"的标准解。
///
/// 调参指南（默认 minCutoff=1.0, beta=0.5, dCutoff=1.0）：
/// - `minCutoff` ↓：静止更稳，但缓慢移动开始拖；↑：慢速抖动透传
/// - `beta` ↑：快速移动更跟手，但高速段抖动也透传；↓：横扫滞后变大
/// - `dCutoff` 是速度估计的截止频率，一般不动（太低会让 beta 调节变迟钝）
public final class OneEuroFilter {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double

    private var xHat: Double?      // 信号低通状态
    private var dxHat = 0.0        // 速度低通状态
    private var lastT: Double?

    public init(minCutoff: Double = 1.0, beta: Double = 0.5, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    /// 回到未初始化状态；下一帧输入直接透传并作为新基线
    public func reset() {
        xHat = nil
        dxHat = 0
        lastT = nil
    }

    /// 送入一个采样。首帧（或 reset 后首帧）原样返回。
    /// - Parameters:
    ///   - x: 采样值（任意单位，输出同单位）
    ///   - t: 单调时间戳（秒）；dt 钳到 ≥1ms，防止除零与爆发式速度估计
    public func filter(_ x: Double, at t: Double) -> Double {
        guard let prevT = lastT, let prevX = xHat else {
            lastT = t
            xHat = x
            return x
        }
        let dt = max(t - prevT, 1e-3)
        lastT = t
        // 速度估计先低通（dCutoff），再据速度抬升信号截止频率
        let edx = lowpass((x - prevX) / dt, prev: dxHat, cutoff: dCutoff, dt: dt)
        dxHat = edx
        let cutoff = minCutoff + beta * abs(edx)
        let out = lowpass(x, prev: prevX, cutoff: cutoff, dt: dt)
        xHat = out
        return out
    }

    /// 一阶低通：α = 1 / (1 + τ/dt)，τ = 1/(2π·cutoff)
    private func lowpass(_ x: Double, prev: Double, cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        let alpha = 1 / (1 + tau / dt)
        return alpha * x + (1 - alpha) * prev
    }
}
