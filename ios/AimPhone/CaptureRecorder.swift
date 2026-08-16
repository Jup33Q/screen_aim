//
//  CaptureRecorder.swift
//  AimPhone（iOS 端）— 识别算法优化用的真机数据采集器：无损 PNG 逐帧录制 + 元数据
//
//  关键约束：全部在 aimphone.capture 串行队列调用（像素数据不进主线程）；
//  录制的必须是检测器实际看到的像素（无损 PNG，禁止重编码），否则离线回放失真
//

import Foundation
import AVFoundation
import CoreImage
import CoreMotion
import UIKit

/// 单帧元数据（meta.jsonl 一行 + 对应一个 PNG）。字段全部可选容错——回放端按 key 取值
struct CaptureFrameMeta {
    let seq: Int
    let pts: Double            // 相机帧 PTS（秒）
    let iso: Float
    let exposureSec: Double
    let zoom: Double
    let rotationRate: Double   // 设备角速度模长（rad/s），静止/运动会话判据
    let markers: [DetectedMarker]
    let aim: CGPoint?
    let detectMs: Double

    func jsonDict() -> [String: Any] {
        var d: [String: Any] = [
            "kind": "frame", "seq": seq, "pts": pts,
            "iso": iso, "exposure": exposureSec, "zoom": zoom,
            "rotRate": rotationRate, "detect_ms": detectMs,
            "markers": markers.map {
                ["id": $0.id, "cx": $0.center.x, "cy": $0.center.y] as [String: Any]
            },
        ]
        if let aim { d["x"] = aim.x; d["y"] = aim.y }
        return d
    }
}

/// 采集录制器：start 后到点自动 finish；PNG 与 meta.jsonl 写临时目录，上传由调用方负责。
/// NOTE: PNG 编码（720p ≈ 30–60ms/帧）在 videoQueue 上同步执行，5fps 抽帧下不影响采集链路
final class CaptureRecorder {
    private(set) var isRecording = false
    private(set) var frameCount = 0
    private var dir: URL?
    private var metaHandle: FileHandle?
    private var startTime: CFAbsoluteTime = 0
    private var duration: CFAbsoluteTime = 10
    private var frameInterval: CFAbsoluteTime = 0.2   // 1/fps
    private var lastRecordPts: CFAbsoluteTime = 0
    private let ciContext = CIContext()
    private let motion = CMMotionManager()
    private var deviceProvider: (() -> AVCaptureDevice?)?

    /// 本次录制内的角速度峰值（上传摘要用）
    private(set) var peakRotRate = 0.0

    /// 预估体积上限：超过则拒绝启动（720p PNG 按 1.5MB/帧估）
    static let maxEstimatedBytes = 200_000_000

    /// 开始录制。返回 nil 表示成功，否则为拒绝原因（UI 状态文案直接展示）
    func start(seconds: Int, fps: Int,
               deviceProvider: @escaping () -> AVCaptureDevice?) -> String? {
        guard !isRecording else { return "已在采集中" }
        let estimated = Int64(seconds * fps) * 1_500_000
        guard estimated < Self.maxEstimatedBytes else {
            return "预估体积超限（\(estimated / 1_000_000)MB > 200MB），缩短时长或降 fps"
        }
        // NOTE: 取卷剩余空间而非精确配额；tmp 目录会被系统清理，但录制期内不会
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSTemporaryDirectory()),
           let free = attrs[.systemFreeSize] as? Int64, free < estimated * 2 {
            return "磁盘空间不足（剩余 \(free / 1_000_000)MB）"
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capture_\(stamp)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("frames", isDirectory: true),
                withIntermediateDirectories: true)
            let metaURL = dir.appendingPathComponent("meta.jsonl")
            FileManager.default.createFile(atPath: metaURL.path, contents: nil)
            metaHandle = try FileHandle(forWritingTo: metaURL)
        } catch {
            return "采集目录创建失败: \(error.localizedDescription)"
        }
        self.dir = dir
        self.deviceProvider = deviceProvider
        duration = CFAbsoluteTime(seconds)
        frameInterval = 1.0 / CFAbsoluteTime(max(1, fps))
        frameCount = 0
        peakRotRate = 0
        lastRecordPts = 0
        startTime = CFAbsoluteTimeGetCurrent()
        isRecording = true
        if motion.isDeviceMotionAvailable { motion.startDeviceMotionUpdates() }
        return nil
    }

    /// 距开始已满 duration 秒
    var isExpired: Bool {
        isRecording && CFAbsoluteTimeGetCurrent() - startTime >= duration
    }

    /// 录制进度（0...1），UI 进度文案用
    var progress: Double {
        guard isRecording else { return 0 }
        return min(1, (CFAbsoluteTimeGetCurrent() - startTime) / duration)
    }

    /// 逐帧入口（localizeFrame 尾部调用）；内部按 fps 节流，到点自动 finish 并回调
    func record(pb: CVPixelBuffer, pts: CFAbsoluteTime, result: LocalizationResult,
                detectMs: Double, onAutoFinish: (URL, Int) -> Void) {
        guard isRecording else { return }
        if isExpired {
            if let out = finish() { onAutoFinish(out.0, out.1) }
            return
        }
        guard pts - lastRecordPts >= frameInterval else { return }
        lastRecordPts = pts
        guard let dir else { return }

        // BGRA → 无损 PNG（检测器看到什么就存什么；WARNING: 不要走 JPEG/HEIC 重编码）
        let image = CIImage(cvPixelBuffer: pb)
        guard let png = ciContext.pngRepresentation(
            of: image, format: .BGRA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()) else { return }
        frameCount += 1
        let name = String(format: "%04d.png", frameCount)
        try? png.write(to: dir.appendingPathComponent("frames/\(name)"))

        let device = deviceProvider?()
        let rot = motion.deviceMotion.map {
            hypot($0.rotationRate.x, hypot($0.rotationRate.y, $0.rotationRate.z))
        } ?? 0
        peakRotRate = max(peakRotRate, rot)
        let meta = CaptureFrameMeta(
            seq: frameCount, pts: pts,
            iso: device?.iso ?? 0,
            exposureSec: device.map { CMTimeGetSeconds($0.exposureDuration) } ?? 0,
            zoom: device.map { Double($0.videoZoomFactor) } ?? 1,
            rotationRate: rot,
            markers: result.markers, aim: result.aim, detectMs: detectMs)
        if let line = try? JSONSerialization.data(withJSONObject: meta.jsonDict()) {
            metaHandle?.write(line)
            metaHandle?.write(Data([0x0A]))
        }
    }

    /// 结束录制。返回 (目录, 帧数)；未在录制返回 nil
    func finish() -> (URL, Int)? {
        guard isRecording, let dir else { return nil }
        isRecording = false
        metaHandle?.closeFile()
        metaHandle = nil
        if motion.isDeviceMotionAvailable { motion.stopDeviceMotionUpdates() }
        return (dir, frameCount)
    }
}
