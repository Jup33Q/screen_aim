//
//  CameraStreamer.swift
//  AimPhone（iOS 端）— 相机采集 + JPEG 推流 + 连接管理 + 扫码配对
//
//  关键约束：像素处理/相机配置全在 aimphone.capture 串行队列；帧中心即瞄准点，
//  识别与映射在 Mac 端（见 docs/architecture.md、docs/protocol.md）
//

import Foundation
import AVFoundation
import CoreImage
import Network
import Combine
import Vision
import UIKit   // UIDevice（采集 session 记录系统版本）

/// 相机可用性状态：驱动权限拒绝 / 配置失败的兜底 UI
enum CameraAvailability: Equatable {
    case unknown, available, unauthorized, failed(String)
}

/// 相机采集 + JPEG 推流（TCP 帧协议: [4字节大端长度][JPEG]）
/// 帧中心即瞄准点，Mac 端负责识别与坐标映射
final class CameraStreamer: NSObject, ObservableObject {
    @Published var isConnected = false
    @Published var statusText = "未连接"
    @Published var framesSent = 0
    @Published var framesSeen = 0      // 相机帧计数（诊断用，验证回调链路）
    @Published var scanning = false    // 正在主动搜索二维码
    @Published var isConnecting = false   // 连接进行中（UI 显示取消按钮）
    @Published var connectionError = false  // 连接最终失败（UI 状态着色用）
    @Published var cameraAvailability: CameraAvailability = .unknown
    @Published var streamPaused = false   // 云台快门键触发：暂停/恢复推流（采集继续，只停发送）
    @Published var localMarkerCount = 0   // 本机识别：本帧检出的定位码数量
    @Published var localAim: CGPoint?     // 本机识别：帧中心映射到屏幕坐标（Mac 语义一致）
    @Published var calibSource = "默认参数"  // 标定映射表来源：默认参数 / Mac 下发
    @Published var pairingQRVisibleOnMac = false  // Mac 端配对二维码当前是否可见（Mac 状态推送，protocol.md §6）

    /// 本机识别（iOS 端坐标转换测试）：与 Mac 端同一套 ScreenAimCore 代码。
    /// 默认映射表对应 Mac 1728×1117 屏 + Calibrator 默认参数（48pt 标记 / 24pt 边距），
    /// 8 项：四角 id0–3 + 四边中点 id4–7（冗余标记，ADR-007）；
    /// Mac 连上后会通过控制信道下发真实标定值覆盖（见 docs/protocol.md §6）
    let localizer = ScreenLocalizer()
    private var lastLocalizeTime: CFAbsoluteTime = 0

    // MARK: 识别调度（无检出自适应降频，update-rate-optimization-plan P1）
    /// 满速档识别间隔：对齐发送闸门 15Hz——识别比发送更勤没有意义
    ///（原 10ms 门 ≈ 相机每帧都识别，是纯粹的浪费）
    private let localizeIntervalFull: CFAbsoluteTime = 1.0 / 15.0
    /// 降频档识别间隔：连续无检出时 3.3Hz 保活扫描，标记回到视野后 300ms 内即可恢复满速
    private let localizeIntervalIdle: CFAbsoluteTime = 0.3
    /// 进降频档的连续 0 检出次数门槛
    private let localizeIdleThreshold = 10
    /// 连续 0 检出（markers.isEmpty）帧计数；仅 videoQueue 访问，检出 >0 立即清零回满速
    private var consecutiveNoMarkerFrames = 0
    /// 当前识别间隔：连续 0 检出满 localizeIdleThreshold 次进降频档
    /// NOTE: 安全性论证——门槛 10 > 断帧滑行预算 maxCoastFrames 5（ADR-013），即降频只在
    /// 滑行早已耗尽、无输出后才触发，不改变白点滑行语义；`registerNoAim` 的滤波器 reset
    /// 路径不受影响。只降识别频率：不影响 JPEG 发送闸门、不影响未连接分支扫码
    ///（checkPairingQR 逻辑不动）、不影响 captureRecorder 录制启动；但录制抽帧由
    /// localizeFrame 尾部驱动，降频档录制抽帧率随之下降——采集会话期间建议人工保持
    /// 标记在视野内
    private var currentLocalizeInterval: CFAbsoluteTime {
        consecutiveNoMarkerFrames >= localizeIdleThreshold ? localizeIntervalIdle : localizeIntervalFull
    }

    let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "aimphone.capture")
    private let ciContext = CIContext()
    var onScanned: ((String, UInt16) -> Void)?   // 扫码成功回调（UI 回填 IP/端口）
    private var lastSendTime: CFAbsoluteTime = 0
    private var lastQRCheck: CFAbsoluteTime = 0
    private var scanDeadline: CFAbsoluteTime = 0
    private var frameCounter = 0
    private var activeDevice: AVCaptureDevice?
    var frameInterval: CFAbsoluteTime = 1.0 / 15.0   // 15fps 足够瞄准用途
    /// 数据采集（protocol.md §11）：Mac 控制帧触发，录完经主 TLV 连接 type 10/11 上传
    private let captureRecorder = CaptureRecorder()
    /// TLV 传输（protocol.md §11，P3 起唯一传输路径；旧 NWConnection 手工分帧实现已拆除）
    private let tlvTransport = TLVTransport()
    /// fast 时敏通道（ADR-017）：主连接就绪后对同一端点开第二条 TLV 连接，专发 localAim，
    /// 躲开视频 JPEG 的 TCP 队头阻塞；断开兜底/下行控制仍只属于主连接
    private let fastTransport = TLVTransport()

    /// 实时亮度调节：v ∈ 0...1 映射到 ISO [minISO, minISO × 10]
    func setBrightness(_ v: Float) {
        videoQueue.async { [weak self] in
            guard let device = self?.activeDevice,
                  device.isExposureModeSupported(.custom) else { return }
            try? device.lockForConfiguration()
            let minISO = device.activeFormat.minISO
            let iso = min(minISO * (1 + v * 9), device.activeFormat.maxISO)
            device.setExposureModeCustom(duration: CMTime(value: 1, timescale: 120),
                                         iso: iso, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    // MARK: 云台按键映射（DockKit accessoryEvents → AVFoundation）

    /// 智控轮盘变焦：factor 为绝对变焦倍率，钳制到当前设备支持范围
    func setZoomFactor(_ factor: Double) {
        videoQueue.async { [weak self] in
            guard let device = self?.activeDevice else { return }
            let clamped = min(max(CGFloat(factor), device.minAvailableVideoZoomFactor),
                              device.maxAvailableVideoZoomFactor)
            try? device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        }
    }

    /// 翻转键：前后摄切换；新设备失败时回滚旧输入，配置沿用 applyDeviceSettings
    func flipCamera() {
        videoQueue.async { [weak self] in
            guard let self, self.sessionConfigured, let current = self.activeDevice else { return }
            let newPosition: AVCaptureDevice.Position = current.position == .back ? .front : .back
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                       position: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: device) else { return }
            let oldInputs = self.session.inputs
            self.session.beginConfiguration()
            oldInputs.forEach { self.session.removeInput($0) }
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.applyDeviceSettings(device)
                self.activeDevice = device
            } else {
                // 回滚：恢复原输入
                oldInputs.forEach { if self.session.canAddInput($0) { self.session.addInput($0) } }
            }
            self.session.commitConfiguration()
        }
    }

    /// 快门键：暂停/恢复推流（不中断采集与扫码逻辑）
    func toggleStreamPaused() {
        DispatchQueue.main.async {
            self.streamPaused.toggle()
        }
    }

    override init() {
        super.init()
        // TLV 传输（新协议，protocol.md §11）：事件/控制回调接线，状态文案与旧路径一致
        tlvTransport.onEvent = { [weak self] e in self?.handleTLVEvent(e) }
        tlvTransport.onControl = { [weak self] data in self?.handleControl(data) }
        tlvTransport.onMessage = { [weak self] msg in self?.handleMessage(msg) }
        // fast 通道（ADR-017）：事件只打日志不碰 UI 状态；就绪即声明角色（hello，§11）；
        // Mac 广播到本连接的 calib/pairingQR 由接收循环自然排空丢弃，不接 onControl/onMessage
        fastTransport.onEvent = { [weak self] e in
            print("FASTCONN \(e)")
            if case .ready = e {
                self?.fastTransport.sendControl(["type": "hello", "role": "fast"])
            }
        }
        // 默认映射表：Calibrator 默认参数（markerSize 48 / inset 24，ADR-010）在 1728×1117 屏上的
        // 8 个标记中心（m+s/2 = 48；W/2 = 864；H/2 = 558.5；上中标记的刘海偏移由 Mac 下发修正）
        localizer.screenCornerMap = [
            0: CGPoint(x: 48, y: 48), 1: CGPoint(x: 1680, y: 48),
            2: CGPoint(x: 1680, y: 1069), 3: CGPoint(x: 48, y: 1069),
            4: CGPoint(x: 864, y: 48), 5: CGPoint(x: 1680, y: 558.5),
            6: CGPoint(x: 864, y: 1069), 7: CGPoint(x: 48, y: 558.5),
        ]
        configureSession()
    }

    // MARK: 相机
    private var sessionConfigured = false

    private func configureSession() {
        // 权限前置检查：拒绝/受限时给出明确状态，避免用户面对黑屏
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.configureSession() }
                    else { self.cameraAvailability = .unauthorized }
                }
            }
            return
        default:
            cameraAvailability = .unauthorized
            return
        }
        guard !sessionConfigured else { return }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            cameraAvailability = .failed("未找到可用后置相机或输入配置失败")
            return
        }
        session.addInput(input)
        applyDeviceSettings(device)
        activeDevice = device

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        sessionConfigured = true
        cameraAvailability = .available
    }

    // MARK: 对焦锁定状态机（P0，focus-dial-plan.md；策略决策见 ADR-018）
    /// 对焦阶段：focusing = continuousAutoFocus 收敛中；locked = 锁定 lensPosition
    private enum FocusPhase { case focusing, locked }
    /// 当前阶段；videoQueue 访问（configureSession 启动期的一次主线程写入除外，彼时采集未启动）
    private var focusPhase: FocusPhase = .focusing
    /// 硬件能力闸门（applyDeviceSettings 按当前设备刷新）：锁定需同时支持 .locked 对焦模式
    /// 与自定义 lensPosition 锁定；任一不满足则静默降级为纯 continuousAutoFocus（模拟器/前摄同理）
    private var focusLockSupported = false
    /// 稳定判定：连续检出 ≥6/8 标记的起始时刻（nil = 当前不稳定）
    private var focusGoodSince: CFAbsoluteTime?
    /// 锁定时连续检出 <4 标记的识别次数（解锁触发计数）
    private var focusBadCount = 0
    /// 稳定判定时长：连续 1s 检出 ≥6 标记（满速档 15Hz ≈ 15 次识别）判定 AF 已收敛
    private let focusStableDuration: CFAbsoluteTime = 1.0
    /// 解锁触发门槛：锁定时连续 10 次识别检出 <4 标记（满速 ≈0.7s）判定画面恶化，
    /// 覆盖遮挡/移远移近场景；瞬态遮挡（手指掠过 1–2 帧）不触发
    private let focusUnlockThreshold = 10

    /// 每次本机识别后喂入检出数（videoQueue 随 localizeFrame 调用）。
    /// 稳定判定 → setFocusModeLocked 锁定；锁定中恶化 → 解锁回 continuousAutoFocus 重 AF。
    /// NOTE: 稳定信号用标记检出数而非持续监听 KVO isAdjustingFocus——检出率直接反映
    /// 画面可用性（失败链终点），isAdjustingFocus 只在锁定决策点瞬读作 AF 收敛佐证
    private func focusFeed(markerCount: Int) {
        guard let device = activeDevice else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if markerCount >= 6 {
            if focusGoodSince == nil { focusGoodSince = now }
        } else {
            focusGoodSince = nil
        }
        switch focusPhase {
        case .focusing:
            guard focusLockSupported,
                  let since = focusGoodSince, now - since >= focusStableDuration,
                  !device.isAdjustingFocus else { return }
            // 锁当前 lensPosition：手机夹云台上、到屏距离物理固定，收敛后锁定消除
            // 对比度 AF 对屏幕内容变化拉风箱产生的失焦帧（focus-dial-plan.md 失败链）
            try? device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: device.lensPosition) { _ in }
            device.unlockForConfiguration()
            focusPhase = .locked
            focusBadCount = 0
            print(String(format: "FOCUS 锁定 lensPosition=%.3f（连续 %.1fs 检出≥6）",
                         device.lensPosition, now - since))
        case .locked:
            if markerCount < 4 {
                focusBadCount += 1
                if focusBadCount >= focusUnlockThreshold {
                    unlockFocus(device, reason: "连续 \(focusBadCount) 次检出 <4")
                }
            } else {
                focusBadCount = 0
            }
        }
    }

    /// 手动干预解锁入口：P1 轮盘对焦微调 / P1.5 点按对焦预留（本批次只留接口不接事件）。
    /// 语义 = 解锁回 continuousAutoFocus，收敛后由 focusFeed 稳定判定自动重锁定
    func requestRefocus() {
        videoQueue.async { [weak self] in
            guard let self, let device = self.activeDevice, self.focusPhase == .locked else { return }
            self.unlockFocus(device, reason: "手动干预")
        }
    }

    /// 解锁回 continuousAutoFocus（videoQueue）；复位稳定判定，等下一次收敛重锁定
    private func unlockFocus(_ device: AVCaptureDevice, reason: String) {
        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        device.unlockForConfiguration()
        focusPhase = .focusing
        focusGoodSince = nil
        focusBadCount = 0
        print("FOCUS 解锁重 AF：\(reason)")
    }

    /// 对焦/白平衡/手动曝光统一配置：初始配置与云台翻转切换前后摄共用
    /// 手动曝光 1/120s（抑制屏幕条纹）+ 低 ISO（防止屏幕白底过曝）
    /// 对焦区域钉帧中心（帧中心即瞄准点）+ 近距范围限制（云台到屏 20–80cm，缩短 AF 行程）
    private func applyDeviceSettings(_ device: AVCaptureDevice) {
        // 前后摄切换走本函数即天然重置对焦状态机：新设备重新 CAF → 稳定 → 锁定（P0）
        focusPhase = .focusing
        focusGoodSince = nil
        focusBadCount = 0
        focusLockSupported = device.isFocusModeSupported(.locked)
            && device.isLockingFocusWithCustomLensPositionSupported
        try? device.lockForConfiguration()
        device.focusMode = .continuousAutoFocus
        // 不支持点对焦的设备（部分前摄）保持默认对焦区域
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
        }
        device.autoFocusRangeRestriction = .near
        if device.isExposureModeSupported(.custom) {
            let iso = min(device.activeFormat.minISO * 1.5, device.activeFormat.maxISO)
            device.setExposureModeCustom(duration: CMTime(value: 1, timescale: 120),
                                         iso: iso, completionHandler: nil)
        }
        device.whiteBalanceMode = .continuousAutoWhiteBalance
        device.unlockForConfiguration()
    }

    func startCamera() {
        videoQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
        startBrowsing()   // 同时开始 Bonjour 自动发现 Mac
    }

    func stopCamera() {
        videoQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: 连接（TLV 单连接；看门狗/重试在 TLVTransport 内，5s×6，解决本地网络授权弹窗期卡死）
    /// 手动断开后禁止 Bonjour 自动重连；只有用户显式连接（按钮/扫码/云台翻转键）才解除
    private var suppressAutoConnect = false

    /// 显式连接（手动输入 IP / 扫码，protocol.md §11）
    func connect(host: String, port: UInt16) {
        guard !isConnecting else { return }
        suppressAutoConnect = false   // 显式连接：恢复自动发现
        isConnecting = true
        connectionError = false
        statusText = "连接中… \(host):\(port)"
        tlvTransport.connect(host: host, port: port)
    }

    /// Bonjour 发现端点的连接（不动 suppressAutoConnect，自动发现路径的抑制检查在浏览回调里完成）
    private func connectEndpoint(_ endpoint: NWEndpoint, label: String) {
        guard !isConnecting else { return }
        isConnecting = true
        connectionError = false
        statusText = "连接中… \(label)"
        tlvTransport.connect(endpoint: endpoint, label: label)
    }

    /// TLV 传输事件 → UI 状态（已在主线程）
    private func handleTLVEvent(_ e: TLVTransport.Event) {
        switch e {
        case .ready(let label):
            isConnecting = false
            isConnected = true
            connectionError = false
            streamPaused = false   // 新连接复位推流暂停，避免"连上但没画面"
            // 扫码搜索途中连上（被动 0.3s 轮询命中二维码）：复位扫描态，
            // 否则遮罩不消失且按钮停在"取消"语义（scanDeadline 还在跑）
            scanning = false
            scanDeadline = 0
            statusText = "已连接 \(label)"
            // 连上后停止 Bonjour 浏览
            browser?.cancel()
            browser = nil
            // fast 时敏通道（ADR-017）：主连接就绪后复用同一端点开第二连接（专发 localAim）
            if let ep = tlvTransport.lastEndpoint {
                fastTransport.connect(endpoint: ep.endpoint, label: ep.label)
            }
        case .waiting:
            statusText = "等待网络…（若弹出本地网络授权请点允许）"
        case .retrying(let text):
            statusText = text
        case .failed(let text):
            isConnecting = false
            connectionError = true
            statusText = text
            fastTransport.close()   // fast 通道随主连接终态失败静默断开
        case .disconnected(let text):
            // NOTE: 已建立的连接意外断开必须清状态，
            // 否则 isConnected 卡 true，扫码按钮被隐藏、scanQRCode 被 guard 拦截
            isConnected = false
            pairingQRVisibleOnMac = false
            connectionError = true
            statusText = "连接已断开: \(text)"
            fastTransport.close()   // fast 通道随主连接静默断开
            startBrowsing()   // 非手动断开：允许 Bonjour 自动找回
        }
    }

    // MARK: Bonjour 自动发现（无需 IP，主方案）
    private var browser: NWBrowser?

    func startBrowsing() {
        guard browser == nil else { return }
        // P3 收敛后唯一服务：`_aimphone._tcp`（TLV 协议，protocol.md §11）
        let b = NWBrowser(for: .bonjour(type: "_aimphone._tcp", domain: nil), using: .tcp)
        browser = b
        b.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                guard let self, !self.isConnected, !self.isConnecting,
                      !self.suppressAutoConnect,   // 手动断开后不再自动重连
                      let result = results.first else { return }
                let label: String
                if case .hostPort(let host, let port) = result.endpoint {
                    label = "\(host):\(port)"
                } else {
                    label = "Bonjour 服务"
                }
                self.statusText = "发现 Mac（\(label)），自动连接…"
                self.connectEndpoint(result.endpoint, label: label)
            }
        }
        b.stateUpdateHandler = { state in
            print("Bonjour browser: \(state)")
        }
        b.start(queue: .main)
    }

    func disconnect() {
        // NOTE: 手动断开必须抑制 Bonjour 自动重连，否则发现回调会立刻把连接拉回来
        suppressAutoConnect = true
        isConnecting = false
        connectionError = false
        // transport 内部补发 mouseUp all + disconnect 兜底帧（protocol.md §7/§8，ADR-008），
        // lastMessage 收尾保证通知帧先于 FIN
        tlvTransport.disconnectGracefully()
        fastTransport.close()   // fast 通道静默断开（无兜底帧语义，ADR-017）
        DispatchQueue.main.async {
            self.isConnected = false
            self.pairingQRVisibleOnMac = false
            self.statusText = "未连接"
            self.startBrowsing()   // 继续浏览只为状态展示，suppressAutoConnect 保证不自动连
        }
    }

    // MARK: 主动扫码（按钮触发，5 秒内逐帧搜索）
    func scanQRCode() {
        guard !isConnected else { return }
        DispatchQueue.main.async {
            self.scanning = true
            self.statusText = "正在搜索二维码…（5 秒）"
        }
        scanDeadline = CFAbsoluteTimeGetCurrent() + 5
    }

    /// 扫码遮罩层的取消路径
    func cancelScan() {
        DispatchQueue.main.async {
            guard self.scanning else { return }
            self.scanning = false
            self.statusText = "已取消扫码"
        }
        scanDeadline = 0
    }

    // MARK: 帧处理与发送
    private func send(jpeg: Data) {
        tlvTransport.send(jpeg: jpeg)
        DispatchQueue.main.async { self.framesSent += 1 }
    }

    /// 切换 Mac 端配对二维码的显示/隐藏（绑定新设备用，protocol.md §7）。
    /// 可见状态由 Mac 推送（pairingQR 消息）驱动 `pairingQRVisibleOnMac`，两端不脱节
    func toggleMacPairingQR() {
        guard isConnected else {
            statusText = "未连接 Mac，无法操作配对码"
            return
        }
        sendControl(["type": "togglePairingQR"])
    }
}

// MARK: - Vision 二维码配对（直接对视频帧识别，不依赖 AVCaptureMetadataOutput）
extension CameraStreamer {
    fileprivate func checkPairingQR(in pb: CVPixelBuffer) {
        let request = VNDetectBarcodesRequest { [weak self] req, _ in
            // NOTE: 连接进行中也要跳过——否则每帧都会重复回调 handleQRText，
            // 状态栏显示"扫码成功"但 connect() 被 isConnecting 守卫吞掉（假成功）
            guard let self, !self.isConnected, !self.isConnecting else { return }
            guard let obs = (req.results as? [VNBarcodeObservation])?
                    .first(where: { $0.symbology == .qr }),
                  let payload = obs.payloadStringValue else { return }
            let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self.scanning = false
                self.handleQRText(text)
            }
        }
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([request])
    }

    private func handleQRText(_ text: String) {
        // 支持两种格式：JSON {"host":"...","port":9100} 或裸文本 host:port（protocol.md §3）。
        // P3 收敛后 port 即 TLV 端口；仍兼容读过渡期二维码的 port2 字段（旧构建的 Mac）
        var host: String?
        var port: UInt16?
        var tlvPort: UInt16?
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let h = json["host"] as? String,
           let p = (json["port"] as? Int).flatMap({ UInt16(exactly: $0) }) {
            host = h; port = p
            tlvPort = (json["port2"] as? Int).flatMap { UInt16(exactly: $0) }
        } else {
            let parts = text.split(separator: ":")
            if parts.count == 2, let p = UInt16(parts[1]) {
                host = String(parts[0]); port = p
            }
        }
        guard let h = host, let p = tlvPort ?? port else {
            statusText = "发现二维码但无法解析: \(text.prefix(40))"
            return
        }
        statusText = "扫码成功 \(h):\(p)，连接中…"
        onScanned?(h, p)      // 回调 UI 回填输入框
        connect(host: h, port: p)
    }
}

// MARK: - 本机识别（iOS 端坐标转换测试）+ 控制信道
extension CameraStreamer {
    /// 通用控制帧发送（iPhone → Mac，TLV type 1，protocol.md §11）
    private func sendControl(_ obj: [String: Any]) {
        tlvTransport.sendControl(obj)
    }

    /// 横屏鼠标模拟器（protocol.md §8）：点击事件上报。button: "left" / "right" / "middle"
    /// 旧协议保留给兼容路径；新 UI 用 sendMouseDown/Up 分离上报（支持拖拽）
    func sendMouseClick(_ button: String) {
        sendControl(["type": "mouseClick", "button": button])
    }

    /// 横屏鼠标模拟器（protocol.md §8）：按键按下上报（落指即发）
    func sendMouseDown(_ button: String) {
        sendControl(["type": "mouseDown", "button": button])
    }

    /// 横屏鼠标模拟器（protocol.md §8）：按键抬起上报；button="all" 为断开前兜底（对全部键补发抬起）
    func sendMouseUp(_ button: String) {
        sendControl(["type": "mouseUp", "button": button])
    }

    /// 横屏鼠标模拟器（protocol.md §8）：滚轮刻度上报，正 = 向上滚
    func sendMouseScroll(_ delta: Int) {
        sendControl(["type": "mouseScroll", "delta": delta])
    }

    /// 对一帧相机画面做本机 ArUco 检测 + 单应映射（在 videoQueue 上同步执行）。
    /// 结果回主线程发布；同时打 LOCALAIM 日志并上报 Mac（控制帧）供两端输出对照。
    /// 上报 JSON 含 detected / missing 两个 ID 数组，Mac 端可分辨具体缺哪个定位码；
    /// `detect_ms` 为本帧检测+映射耗时（Phase 0 基线测量用，只加不删保持向后兼容）
    fileprivate func localizeFrame(_ pb: CVPixelBuffer, timestamp: CFAbsoluteTime) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let t0 = CFAbsoluteTimeGetCurrent()
        // 传采集 PTS 而非墙钟：滤波器 dt 精度直接影响 One Euro 消抖效果（Phase 1.3）
        let result = localizer.localize(bgra: base, width: w, height: h, bytesPerRow: bpr,
                                        timestamp: timestamp)
        // 无检出降频档位切换（P1）：连续 0 检出满门槛进 300ms 降频档，任一帧检出即回满速
        if result.markers.isEmpty {
            consecutiveNoMarkerFrames += 1
        } else {
            consecutiveNoMarkerFrames = 0
        }
        // 对焦锁定状态机喂入（P0）：检出数驱动稳定判定/恶化解锁
        focusFeed(markerCount: result.markers.count)
        let detectMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        DispatchQueue.main.async {
            self.localMarkerCount = result.markers.count
            self.localAim = result.aim
        }
        let detectedIds = result.markers.map { $0.id }.sorted()
        let missingIds = (0...7).filter { !detectedIds.contains($0) }   // 标记全集 = id0–7（ADR-007）
        // 每次识别都上报（不抽稀，ADR-009；满速档 ≈15Hz，P1 降频档 3.3Hz）：
        // Mac 端白点覆盖层/debug 对照的流畅度优先于控制信道流量
        //（光标跟随走 Mac 侧视频帧识别，与本上报无关）
        if let aim = result.aim {
            print(String(format: "LOCALAIM screen=(%.1f, %.1f) markers=%d/%d detected=%@ q=%@ det=%.1fms",
                         aim.x, aim.y, result.markers.count, 8,
                         detectedIds.map(String.init).joined(separator: ","),
                         result.quality?.rawValue ?? "-", detectMs))
        } else if !missingIds.isEmpty {
            print(String(format: "LOCALAIM 检出不足: detected=%@ missing=%@ det=%.1fms",
                         "\(detectedIds)", "\(missingIds)", detectMs))
        }
        // 本机识别结果上报 Mac（含无瞄准点的空结果 + 各标记识别状态，便于离线分析缺哪个标记）
        var msg: [String: Any] = ["type": "localAim",
                                  "markers": result.markers.count,
                                  "detected": detectedIds,
                                  "missing": missingIds,
                                  "detect_ms": detectMs]
        if let aim = result.aim {
            msg["x"] = aim.x; msg["y"] = aim.y
            // 输出等级（WP1，protocol.md §7：只加不删，旧版 Mac 忽略该字段）
            if let q = result.quality { msg["quality"] = q.rawValue }
        }
        // localAim 走 fast 时敏通道（ADR-017：躲开视频 JPEG 的 TCP 队头阻塞）；
        // fast 未就绪回退主连接，白点不中断（只是回到旧 HoL 行为）
        (fastTransport.isConnected ? fastTransport : tlvTransport).sendControl(msg)
        // 数据采集（protocol.md §10）：录制中则抽帧落盘；到点自动 finish 并上传。
        // 注意此时 pb 仍持锁（本函数 defer 解锁），PNG 编码可以直接读
        captureRecorder.record(pb: pb, pts: timestamp, result: result, detectMs: detectMs)
        { [weak self] dir, n in
            self?.finishCaptureAndUpload(dir: dir, frames: n)
        }
        if captureRecorder.isRecording, captureRecorder.frameCount > 0 {
            let pct = Int(captureRecorder.progress * 100)
            DispatchQueue.main.async { [weak self] in
                self?.statusText = "采集中 \(pct)%（\(self?.captureRecorder.frameCount ?? 0) 帧）"
            }
        }
    }

    /// 结束采集并经主 TLV 连接上传（type 10/11，§11；captureStop 与到点自动停止共用，videoQueue 上调用）
    private func finishCaptureAndUpload(dir: URL, frames: Int) {
        DispatchQueue.main.async { self.statusText = "采集完成（\(frames) 帧），上传中…" }
        tlvTransport.uploadCapture(dir: dir, total: frames,
                                   peakRotRate: captureRecorder.peakRotRate) { [weak self] text in
            self?.statusText = text
        }
    }

    /// 解析 Mac 下发的控制消息（calib 标定表 / pairingQR 二维码可见状态 / capture 触发）
    private func handleControl(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "calib":
            guard let markers = obj["markers"] as? [String: [Double]] else { return }
            var map: [Int: CGPoint] = [:]
            for (k, v) in markers {
                guard let id = Int(k), v.count == 2 else { continue }
                map[id] = CGPoint(x: v[0], y: v[1])
            }
            // 冗余标记模式 ≥4 项即接受（ADR-007）；旧版 Mac 只发 4 角也照常工作
            guard map.count >= 4 else { return }
            videoQueue.async {
                self.localizer.screenCornerMap = map
                // 口语化滤波预设（WP3.4，protocol.md §6：只加不删的可选字段，
                // 旧版 Mac 不下发则保持编译期默认「日常跟手」）
                if let name = obj["filterPreset"] as? String,
                   let preset = AimFilterPreset(rawValue: name) {
                    self.localizer.applyFilterPreset(preset)
                }
            }
            DispatchQueue.main.async {
                self.calibSource = "Mac 下发"
            }
            print("CALIB received: \(map)")
        case "pairingQR":
            // Mac 配对二维码可见状态推送（按钮高亮跟随真实状态）
            DispatchQueue.main.async {
                self.pairingQRVisibleOnMac = obj["visible"] as? Bool ?? false
            }
        case "captureStart":
            // 数据采集触发（protocol.md §10）：Mac 标定层按钮下发，录制走 videoQueue
            let seconds = obj["seconds"] as? Int ?? 10
            let fps = obj["fps"] as? Int ?? 5
            videoQueue.async {
                if let err = self.captureRecorder.start(
                    seconds: seconds, fps: fps,
                    deviceProvider: { [weak self] in self?.activeDevice }) {
                    DispatchQueue.main.async { self.statusText = err }
                }
            }
        case "captureStop":
            videoQueue.async {
                if let (dir, n) = self.captureRecorder.finish() {
                    self.finishCaptureAndUpload(dir: dir, frames: n)
                }
            }
        default:
            break
        }
    }

    /// 处理 Mac 下发的结构化消息（TLV type 2 Codable 信封，protocol.md §11；主线程）
    private func handleMessage(_ msg: AimMessage) {
        switch msg {
        case .aimUIHover(let overlapping):
            // 白点进入 ScreenAim 悬浮 UI（顶部控制面板 / 定位码白卡）震一次（边沿触发，
            // 离开不震）；震感样式与 ContentView 既有轻反馈一致
            if overlapping {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }
}

extension CameraStreamer: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 本机识别：两档间隔门控（满速 15Hz / 连续无检出降频 3.3Hz，见 currentLocalizeInterval），
        // alwaysDiscardsLateVideoFrames 保证队列不积压，与推流/扫码互不阻塞（同队列顺序执行）
        let now0 = CFAbsoluteTimeGetCurrent()
        if now0 - lastLocalizeTime >= currentLocalizeInterval {
            lastLocalizeTime = now0
            localizeFrame(pb, timestamp: CMTimeGetSeconds(
                CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
        }

        // DEBUG: 帧计数诊断（每 15 帧刷一次 UI，验证回调链路）
        frameCounter += 1
        if frameCounter % 15 == 0 {
            DispatchQueue.main.async { self.framesSeen = self.frameCounter }
        }

        // 未连接时：被动每 0.3s 一次；按下扫描键后逐帧搜索直到超时
        if !isConnected {
            let now = CFAbsoluteTimeGetCurrent()
            if scanning {
                if now > scanDeadline {
                    DispatchQueue.main.async {
                        self.scanning = false
                        self.statusText = "未发现二维码，请对准后重试"
                    }
                } else {
                    checkPairingQR(in: pb)
                }
            } else if !suppressAutoConnect, now - lastQRCheck >= 0.3 {
                // NOTE: 手动断开后（suppressAutoConnect）关闭被动扫码——手机固定在云台上
                // 仍对着屏幕，Mac 重显二维码会被立刻重新识别并自动回连，架空手动断开语义
                lastQRCheck = now
                checkPairingQR(in: pb)
            }
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSendTime >= frameInterval else { return }
        lastSendTime = now
        guard !streamPaused else { return }   // 云台快门键暂停推流：帧照采，不发送
        let image = CIImage(cvPixelBuffer: pb)
        guard let jpeg = ciContext.jpegRepresentation(of: image,
                                                      colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6])
        else { return }
        send(jpeg: jpeg)
    }
}
