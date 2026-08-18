//
//  MotionSampler.swift
//  AimPhone（iOS 端）— CoreMotion deviceMotion 100Hz 采样器（IMU 辅助定位 WP-I1，只采不融）
//
//  关键约束：采样回调在 aimphone.motion 串行队列，读侧在 aimphone.capture 队列，
//  样本数组跨队列访问必须走内部锁；`CMDeviceMotion.timestamp` 与相机帧 PTS 同为
//  mach boot 时钟（秒），可直接对齐（docs/imu-fusion-plan.md §0.4）
//

import Foundation
import CoreMotion

/// 单条运动样本：deviceMotion 融合输出（rotationRate 已扣零偏）
struct MotionSample {
    let t: Double                  // mach boot 时钟秒，与相机帧 PTS 同时钟
    let wx, wy, wz: Double         // rotationRate（rad/s，设备坐标系）
    let qx, qy, qz, qw: Double     // attitude 四元数（xArbitraryZVertical 参考系，无磁北校正）
}

/// deviceMotion 100Hz 采样器：跟随采集会话启停（WP-I1 尖刺，只采不融，对识别/推流零影响）。
///
/// 约束与副作用：同一 app 内应只有本类持 CMMotionManager（多实例的 start/stop
/// 语义互相干扰，官方未保证）；样本全程驻留内存，10s@100Hz ≈ 1000 条，量级可忽略。
final class MotionSampler {
    /// 采样率：100Hz（方案 §1；deviceMotion 系统融合输出上限即 100Hz 量级）
    static let updateInterval: TimeInterval = 0.01

    /// NOTE: CoreMotion 回调 API 只收 OperationQueue；串行化由 maxConcurrentOperationCount=1
    /// 保证，语义等同串行 DispatchQueue（aimphone.motion）
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "aimphone.motion"
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private let motion = CMMotionManager()
    private let lock = NSLock()
    private var samples: [MotionSample] = []

    var isAvailable: Bool { motion.isDeviceMotionAvailable }

    /// 采样窗口半宽（秒）：meta.jsonl 每帧携带 PTS 前后各 0.15s 的样本，
    /// 覆盖 15Hz 识别帧间隔（66ms）与 WP-I2 外推封顶（120ms）的分析需求
    static let windowHalf: Double = 0.15

    /// 开始采样（清空上一轮缓冲）。重复调用安全（先停后清）
    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        stop()
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        motion.deviceMotionUpdateInterval = Self.updateInterval
        // 不指定参考系 = xArbitraryZVertical：无磁北校正，yaw 缓慢漂移——
        // 漂移率正是四问之④要测的量，不能用磁强计把它"修"掉
        motion.startDeviceMotionUpdates(to: queue) { [weak self] dm, _ in
            guard let self, let dm else { return }
            let q = dm.attitude.quaternion
            let s = MotionSample(t: dm.timestamp,
                                 wx: dm.rotationRate.x, wy: dm.rotationRate.y, wz: dm.rotationRate.z,
                                 qx: q.x, qy: q.y, qz: q.z, qw: q.w)
            self.lock.lock()
            self.samples.append(s)
            self.lock.unlock()
        }
    }

    /// 停止采样；缓冲保留供停止后补写尾帧 meta（finish 时尾帧"之后"的窗口在这里截断）
    func stop() {
        if motion.isDeviceMotionAvailable { motion.stopDeviceMotionUpdates() }
    }

    /// 取 [t - half, t + half] 窗口内的样本快照（跨队列读，返回拷贝）。
    /// "之后"一侧只含已到达的样本——录制中调用时自然截断到当前时刻
    func window(around t: Double, half: Double = MotionSampler.windowHalf) -> [MotionSample] {
        lock.lock()
        defer { lock.unlock() }
        return samples.filter { $0.t >= t - half && $0.t <= t + half }
    }

    /// 最新样本的角速度模长（rad/s）；无样本时 0。替代原 CaptureRecorder 自持
    /// CMMotionManager 的轮询，避免 app 内多实例 deviceMotion 的未定义交互
    func latestRotRate() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let s = samples.last else { return 0 }
        return hypot(s.wx, hypot(s.wy, s.wz))
    }
}
