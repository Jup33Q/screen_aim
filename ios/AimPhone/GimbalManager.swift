//
//  GimbalManager.swift
//  AimPhone（iOS 端）— DockKit 云台适配层：状态感知 + 按键事件 → 动作闭包分发
//
//  关键约束：全类 @MainActor；DockKit 仅真机 SDK，模拟器/无配件全路径静默降级；
//  按键映射语义见类文档与 docs/decisions.md ADR-005
//

import Foundation
import AVFoundation
import Combine
import OSLog

// NOTE: DockKit 框架仅存在于真机 SDK（模拟器 SDK 没有该模块）：
// 用 canImport 守卫所有 DockKit 依赖代码，模拟器构建时整个适配层自动降级为空操作。
#if canImport(DockKit)
import DockKit
#endif

private let gimbalLog = Logger(subsystem: "com.screenaim.AimPhone", category: "Gimbal")

/// DockKit 云台适配层（目标硬件：Insta360 Flow 2 Pro / Flow Pro 等 DockKit 认证支架）
///
/// 本 App 用途是瞄准屏幕，**不需要人物追踪**：docked 时主动 `setSystemTrackingEnabled(false)`，
/// 退出/退后台/undock 时恢复（该设置不持久，但按规范显式恢复）。
///
/// 云台按键 → App 操作（iOS 17.4+ accessoryEvents，动作由 ContentView 注入闭包）：
/// - 扳机 `.button(id:)`       → 按住 = 功能修饰键（按住时机械臂锁定，功能键才生效）
/// - 快门键 `.cameraShutter`   → 扫码配对 / 取消扫码（需按住扳机）
/// - 翻转键 `.cameraFlip`      → 连接 Mac / 断开（需按住扳机）
/// - 智控轮盘 `.cameraZoom`    → 亮度调节（需按住扳机；factor 增量 → 亮度增减，基线始终更新防跳变）
///
/// 状态感知（L1）：订阅 dock/undock + 电量（iOS 18+），UI 显示云台 pill。
/// 模拟器与无配件环境全路径优雅降级：所有 DockKit 调用失败仅记录日志。
@MainActor
final class GimbalManager: ObservableObject {
    // MARK: - 发布给 UI 的状态
    @Published private(set) var docked = false
    @Published private(set) var accessoryModel = ""          // hardwareModel，如 "Flow 2 Pro"
    @Published private(set) var firmwareVersion = ""
    @Published private(set) var batteryLevel: Float?          // iOS 18+，0...1
    @Published private(set) var lowBattery = false
    @Published private(set) var triggerHeld = false           // 扳机按住中：功能键才生效（机械臂同时锁定）
    @Published private(set) var trackingButtonEnabled = false // 云台追踪键状态（扳机可能走这个通道上报）
    /// DEBUG: 最近一条云台事件描述（上屏显示，定位扳机事件通道用）
    @Published private(set) var lastEvent = "等待事件…"
    /// DEBUG: 带时间戳的事件历史（新事件在前，最多 20 条）
    @Published private(set) var eventHistory: [String] = []

    /// 当前按住的按键 id 集合（扳机是主要的 .button 来源；任何按键按住即视为功能修饰）
    private var pressedButtons = Set<Int>()

    private static let eventTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 记录事件：上屏（最近一条 + 历史列表）+ 系统日志
    private func reportEvent(_ text: String) {
        lastEvent = text
        let stamp = Self.eventTimeFormatter.string(from: Date())
        eventHistory.insert("\(stamp) \(text)", at: 0)
        if eventHistory.count > 20 { eventHistory.removeLast() }
        gimbalLog.notice("\(text, privacy: .public)")
    }

    // MARK: - 按键动作（ContentView 注入，全部 MainActor 上下文执行）
    var onShutter: (() -> Void)?            // 快门键 → 扫码/取消扫码
    var onFlip: (() -> Void)?               // 翻转键 → 连接/断开
    var onZoomDelta: ((Double) -> Void)?    // 轮盘增量 → 亮度调节

#if canImport(DockKit)
    private var managerTask: Task<Void, Never>?
    private var accessoryTasks: [Task<Void, Never>] = []
    /// docked 期间持有的配件，供事件/电量流使用
    private var accessory: DockAccessory?
    /// 轮盘变焦倍率基线：首个 cameraZoom 事件只建基线不动作，防止亮度跳变
    private var lastZoomFactor: Double?
    /// 记录本 App 是否关闭过系统追踪，退出时据此恢复
    private var trackingDisabledByUs = false
#endif

    // MARK: - 生命周期

    func start() {
#if canImport(DockKit)
        guard managerTask == nil else { return }
        managerTask = Task { [weak self] in
            await self?.listenAccessoryStateChanges()
        }
#endif
    }

    /// 退后台 / 视图消失时调用：停订阅、恢复系统追踪、重置 UI 状态（避免回前台显示过期 pill）
    func stop() {
#if canImport(DockKit)
        managerTask?.cancel()
        managerTask = nil
        cancelAccessoryTasks()
        restoreSystemTrackingIfNeeded()
        handleUndocked()
#endif
    }

#if canImport(DockKit)
    // MARK: - L1：dock / undock 状态流（仅有的两个必处理状态）

    private func listenAccessoryStateChanges() async {
        do {
            for await change in try DockAccessoryManager.shared.accessoryStateChanges {
                guard !Task.isCancelled else { return }
                // 追踪键（很可能就是扳机）状态变化也走这个流，必须记录
                if change.trackingButtonEnabled != trackingButtonEnabled {
                    reportEvent("追踪键 → \(change.trackingButtonEnabled ? "开" : "关")")
                }
                trackingButtonEnabled = change.trackingButtonEnabled
                switch change.state {
                case .docked:
                    guard let dock = change.accessory else { continue }
                    await handleDocked(dock)
                case .undocked:
                    handleUndocked()
                @unknown default:
                    break
                }
            }
        } catch {
            // 模拟器 / 不支持 DockKit 的机型（SE 3、16e）/ 权限异常：静默降级
            gimbalLog.error("accessoryStateChanges 终止: \(error.localizedDescription, privacy: .public)")
            reportEvent("状态流错误: \(error.localizedDescription)")
        }
        // 流结束视为无配件
        if !Task.isCancelled { handleUndocked() }
    }

    private func handleDocked(_ dock: DockAccessory) async {
        // 追踪键状态变化会重复推 .docked——同一配件只初始化一次
        if docked, accessory?.identifier == dock.identifier { return }
        accessory = dock
        docked = true
        accessoryModel = dock.hardwareModel ?? "DockKit 云台"
        firmwareVersion = dock.firmwareVersion ?? ""
        lastZoomFactor = nil   // 重新 dock 后重建轮盘基线
        reportEvent("docked: \(accessoryModel)")

        // 本 App 不需要人物追踪：关闭系统追踪，避免云台跟着人转
        do {
            try await DockAccessoryManager.shared.setSystemTrackingEnabled(false)
            trackingDisabledByUs = true
        } catch {
            gimbalLog.error("关闭系统追踪失败: \(error.localizedDescription, privacy: .public)")
        }

        startAccessoryStreams(dock)
    }

    private func handleUndocked() {
        cancelAccessoryTasks()
        accessory = nil
        lastZoomFactor = nil
        pressedButtons.removeAll()
        triggerHeld = false
        trackingButtonEnabled = false
        lastEvent = "等待事件…"
        docked = false
        accessoryModel = ""
        firmwareVersion = ""
        batteryLevel = nil
        lowBattery = false
        restoreSystemTrackingIfNeeded()
    }

    private func restoreSystemTrackingIfNeeded() {
        guard trackingDisabledByUs else { return }
        trackingDisabledByUs = false
        Task {
            try? await DockAccessoryManager.shared.setSystemTrackingEnabled(true)
        }
    }

    private func cancelAccessoryTasks() {
        accessoryTasks.forEach { $0.cancel() }
        accessoryTasks.removeAll()
    }

    // MARK: - 配件作用域的状态流（随 dock/undock 启停）

    private func startAccessoryStreams(_ dock: DockAccessory) {
        cancelAccessoryTasks()

        // 云台物理按键事件（iOS 17.4+）→ App 操作
        if #available(iOS 17.4, *) {
            accessoryTasks.append(Task { [weak self] in
                await self?.listenAccessoryEvents(dock)
            })
        }

        if #available(iOS 18.0, *) {
            accessoryTasks.append(Task { [weak self] in
                await self?.listenBatteryStates(dock)
            })
        }
    }

    /// 按键事件分发：扳机（.button）按住 = 功能修饰键；快门/翻转/轮盘只在扳机按住时生效，
    /// 避免直接转轮盘时机械臂跟随运动与 App 功能打架。
    /// 动作语义由注入的闭包决定，本类只做事件 → 动作转换。
    @available(iOS 17.4, *)
    private func listenAccessoryEvents(_ dock: DockAccessory) async {
        do {
            for await event in try dock.accessoryEvents {
                guard !Task.isCancelled else { return }
                switch event {
                case .cameraShutter:
                    reportEvent("快门键 (held=\(triggerHeld))")
                    guard triggerHeld else { continue }
                    onShutter?()
                case .cameraFlip:
                    reportEvent("翻转键 (held=\(triggerHeld))")
                    guard triggerHeld else { continue }
                    onFlip?()
                case .cameraZoom(let factor):
                    // 轮盘给的是绝对变焦倍率；转亮度用增量：基线始终更新，动作只在扳机按住时触发
                    if let last = lastZoomFactor {
                        let delta = factor - last
                        reportEvent("轮盘 Δ\(String(format: "%.2f", delta)) (held=\(triggerHeld))")
                        if delta != 0, triggerHeld { onZoomDelta?(delta) }
                    } else {
                        reportEvent("轮盘基线 \(String(format: "%.2f", factor))")
                    }
                    lastZoomFactor = factor
                case .button(let id, let pressed):
                    // 扳机/其他按键：维护按住集合，充当功能修饰键
                    if pressed { pressedButtons.insert(id) } else { pressedButtons.remove(id) }
                    let held = !pressedButtons.isEmpty
                    if held != triggerHeld { triggerHeld = held }
                    reportEvent("按键 id=\(id) \(pressed ? "按下" : "松开")")
                @unknown default:
                    break
                }
            }
        } catch {
            if !Task.isCancelled {
                gimbalLog.error("accessoryEvents 终止: \(error.localizedDescription, privacy: .public)")
                reportEvent("事件流错误: \(error.localizedDescription)")
            }
        }
    }

    @available(iOS 18.0, *)
    private func listenBatteryStates(_ dock: DockAccessory) async {
        do {
            for await battery in try dock.batteryStates {
                guard !Task.isCancelled else { return }
                // Flow 2 Pro 单电池；多电池云台需用 battery.name 区分
                batteryLevel = Float(battery.batteryLevel)
                lowBattery = battery.lowBattery
            }
        } catch {
            if !Task.isCancelled {
                gimbalLog.error("batteryStates 终止: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
#endif
}
