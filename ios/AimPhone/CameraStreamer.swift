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

    let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "aimphone.capture")
    private let ciContext = CIContext()
    private var connection: NWConnection?
    private var retryCount = 0
    var onScanned: ((String, UInt16) -> Void)?   // 扫码成功回调（UI 回填 IP/端口）
    private var lastSendTime: CFAbsoluteTime = 0
    private var lastQRCheck: CFAbsoluteTime = 0
    private var scanDeadline: CFAbsoluteTime = 0
    private var frameCounter = 0
    private var activeDevice: AVCaptureDevice?
    var frameInterval: CFAbsoluteTime = 1.0 / 15.0   // 15fps 足够瞄准用途
    /// 数据采集（protocol.md §10）：Mac 控制帧触发，录完上传到 Mac:port+1
    private let captureRecorder = CaptureRecorder()
    /// 当前连接的解析后地址（Bonjour 连接在 ready 后从 currentPath 取），采集上传用
    private var connectedHostPort: (NWEndpoint.Host, NWEndpoint.Port)?

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

    /// 对焦/白平衡/手动曝光统一配置：初始配置与云台翻转切换前后摄共用
    /// 手动曝光 1/120s（抑制屏幕条纹）+ 低 ISO（防止屏幕白底过曝）
    private func applyDeviceSettings(_ device: AVCaptureDevice) {
        try? device.lockForConfiguration()
        device.focusMode = .continuousAutoFocus
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

    // MARK: 连接（带 5 秒看门狗 + 自动重试，解决本地网络授权弹窗期连接卡死）
    /// 手动断开后禁止 Bonjour 自动重连；只有用户显式连接（按钮/扫码/云台翻转键）才解除
    private var suppressAutoConnect = false

    func connect(host: String, port: UInt16) {
        guard !isConnecting else { return }
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        suppressAutoConnect = false   // 显式连接：恢复自动发现
        retryCount = 0
        isConnecting = true
        connectionError = false
        statusText = "连接中… \(host):\(port)"
        startConnection(endpoint: .hostPort(host: NWEndpoint.Host(host), port: p),
                        label: "\(host):\(port)")
    }

    /// Bonjour 发现的直连端点
    func connectEndpoint(_ endpoint: NWEndpoint, label: String) {
        guard !isConnecting else { return }
        retryCount = 0
        isConnecting = true
        connectionError = false
        statusText = "连接中… \(label)"
        startConnection(endpoint: endpoint, label: label)
    }

    private func startConnection(endpoint: NWEndpoint, label: String) {
        connection?.cancel()
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                // NOTE: 必须校验连接身份——旧连接（已 cancel/被替换）的迟到状态回调
                // 不允许影响新连接，否则旧连接的 .failed 会用旧 endpoint 触发重试，
                // 把正在进行的新连接 cancel 掉（断开后重连失败的根因之一）
                guard let self, self.connection === conn else { return }
                switch state {
                case .ready:
                    self.retryCount = 0
                    self.isConnecting = false
                    self.isConnected = true
                    self.connectionError = false
                    self.streamPaused = false   // 新连接复位推流暂停，避免"连上但没画面"
                    self.statusText = "已连接 \(label)"
                    // 记录解析后的对端地址（Bonjour 服务端点没有裸 IP，采集上传要按 IP 直连 port+1）
                    if case .hostPort(let host, let port) = conn.currentPath?.remoteEndpoint {
                        self.connectedHostPort = (host, port)
                    }
                    // 连上后停止 Bonjour 浏览
                    self.browser?.cancel()
                    self.browser = nil
                    // 控制信道：接收 Mac 下发的标定映射表（docs/protocol.md §6）
                    self.receiveControl(conn)
                case .failed(let e):
                    if self.isConnected {
                        // NOTE: 已建立的连接意外断开（网络波动/Mac 端退出）：
                        // 必须清状态，否则 isConnected 永远卡 true，扫码按钮被隐藏、
                        // scanQRCode 被 guard 拦截——表现为"断开后再次扫码无反应"
                        self.isConnected = false
                        self.connection = nil
                        self.pairingQRVisibleOnMac = false
                        self.connectionError = true
                        self.statusText = "连接已断开: \(e.localizedDescription)"
                        self.startBrowsing()   // 非手动断开：允许 Bonjour 自动找回
                    } else if self.isConnecting && self.retryCount < 6 {
                        // 失败快速重试，不傻等看门狗
                        self.retryCount += 1
                        self.statusText = "连接失败，1 秒后第 \(self.retryCount) 次重试…"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                            guard let self, self.isConnecting, !self.isConnected,
                                  self.connection === conn else { return }
                            self.startConnection(endpoint: endpoint, label: label)
                        }
                    } else if self.isConnecting {
                        self.isConnecting = false
                        self.connectionError = true
                        self.statusText = "连接失败: \(e.localizedDescription)"
                    }
                case .waiting:
                    self.statusText = "等待网络…（若弹出本地网络授权请点允许）"
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        conn.start(queue: .global(qos: .userInitiated))

        // NOTE: 看门狗——5 秒内没 ready 就取消重来；本地网络授权弹窗期的连接会永久卡死，必须重启
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.isConnecting, !self.isConnected,
                  self.connection === conn else { return }
            self.retryCount += 1
            if self.retryCount <= 6 {
                self.statusText = "连接超时，第 \(self.retryCount) 次重试…"
                self.startConnection(endpoint: endpoint, label: label)
            } else {
                self.isConnecting = false
                self.connectionError = true
                self.statusText = "多次连接失败：检查 Mac 服务是否在运行，以及 设置 > AimPhone 的本地网络权限"
            }
        }
    }

    // MARK: Bonjour 自动发现（无需 IP，主方案）
    private var browser: NWBrowser?

    func startBrowsing() {
        guard browser == nil else { return }
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
        retryCount = 0
        if let conn = connection, isConnected {
            // 先通知 Mac「手机主动断开」（protocol.md §7 disconnect），Mac 收到后
            // 重新显示配对二维码并刷新为当前 IP；finalMessage 保证通知帧先于 FIN 发出。
            // 断开前对鼠标键补发 up-all 兜底（§8，ADR-008）：防止按住中时断连导致 Mac 键卡死
            sendControl(["type": "mouseUp", "button": "all"])
            sendControl(["type": "disconnect"])
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { _ in conn.cancel() })
        } else {
            connection?.cancel()
        }
        connection = nil
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
        guard let conn = connection else { return }
        var len = UInt32(jpeg.count).bigEndian
        let header = Data(bytes: &len, count: 4)
        conn.send(content: header + jpeg, completion: .idempotent)
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
        // 支持两种格式：JSON {"host":"...","port":9100} 或裸文本 host:port
        var host: String?
        var port: UInt16?
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let h = json["host"] as? String,
           let p = (json["port"] as? Int).flatMap({ UInt16(exactly: $0) }) {
            host = h; port = p
        } else {
            let parts = text.split(separator: ":")
            if parts.count == 2, let p = UInt16(parts[1]) {
                host = String(parts[0]); port = p
            }
        }
        guard let h = host, let p = port else {
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
    /// 通用控制帧发送（iPhone → Mac，长度字最高位置 1，protocol.md §7）
    private func sendControl(_ obj: [String: Any]) {
        guard let conn = connection, isConnected,
              let json = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var len = (UInt32(json.count) | 0x8000_0000).bigEndian
        let header = withUnsafeBytes(of: &len) { Data($0) }
        conn.send(content: header + json, completion: .idempotent)
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
        let detectMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        DispatchQueue.main.async {
            self.localMarkerCount = result.markers.count
            self.localAim = result.aim
        }
        let detectedIds = result.markers.map { $0.id }.sorted()
        let missingIds = (0...7).filter { !detectedIds.contains($0) }   // 标记全集 = id0–7（ADR-007）
        // 每帧识别每帧上报（不抽稀，≈15Hz，ADR-009）：Mac 端白点覆盖层/debug 对照的流畅度
        // 优先于控制信道流量（光标跟随走 Mac 侧视频帧识别，与本上报无关）
        if let aim = result.aim {
            print(String(format: "LOCALAIM screen=(%.1f, %.1f) markers=%d/%d detected=%@ det=%.1fms",
                         aim.x, aim.y, result.markers.count, 8,
                         detectedIds.map(String.init).joined(separator: ","), detectMs))
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
        if let aim = result.aim { msg["x"] = aim.x; msg["y"] = aim.y }
        sendControl(msg)
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

    /// 结束采集并上传到 Mac:port+1（captureStop 控制帧与到点自动停止共用，videoQueue 上调用）
    private func finishCaptureAndUpload(dir: URL, frames: Int) {
        DispatchQueue.main.async { self.statusText = "采集完成（\(frames) 帧），上传中…" }
        guard let (host, port) = connectedHostPort,
              let upPort = NWEndpoint.Port(rawValue: port.rawValue + 1) else {
            DispatchQueue.main.async { self.statusText = "采集上传失败：无对端地址" }
            return
        }
        let conn = NWConnection(to: .hostPort(host: host, port: upPort), using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.sendCaptureRecords(conn: conn, dir: dir, total: frames)
            case .failed(let e):
                DispatchQueue.main.async { self?.statusText = "采集上传失败: \(e.localizedDescription)" }
            default:
                break
            }
        }
        conn.start(queue: videoQueue)
    }

    /// 逐条流式发送采集记录（[4B jsonLen][json][4B binLen][bin]，contentProcessed 串行背压）。
    /// 顺序：session 记录 → 每帧一条（meta.jsonl 行 + PNG）→ end 记录（finalMessage 收尾）
    private func sendCaptureRecords(conn: NWConnection, dir: URL, total: Int) {
        var uts = utsname()
        uname(&uts)
        let model = withUnsafeBytes(of: &uts.machine) { ptr in
            String(cString: ptr.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let session: [String: Any] = ["kind": "session", "device": model,
                                      "os": UIDevice.current.systemVersion]
        guard let metaRaw = FileManager.default.contents(
            atPath: dir.appendingPathComponent("meta.jsonl").path),
            let metaText = String(data: metaRaw, encoding: .utf8) else { conn.cancel(); return }
        let lines = metaText.split(separator: "\n").map(String.init)

        // records 惰性求值：session/end 无二进制体（binLen=0）
        func recordData(_ json: Data, bin: Data?) -> Data {
            var jl = UInt32(json.count).bigEndian
            var bl = UInt32(bin?.count ?? 0).bigEndian
            var out = withUnsafeBytes(of: &jl) { Data($0) }
            out.append(json)
            out.append(withUnsafeBytes(of: &bl) { Data($0) })
            if let bin { out.append(bin) }
            return out
        }
        func send(_ data: Data, then: @escaping () -> Void) {
            conn.send(content: data, completion: .contentProcessed { _ in then() })
        }
        func sendFrame(_ i: Int) {
            guard i < lines.count else {
                let end: [String: Any] = ["kind": "end", "frames": total,
                                          "peakRotRate": captureRecorder.peakRotRate]
                send(recordData(try! JSONSerialization.data(withJSONObject: end), bin: nil)) {
                    conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                              completion: .contentProcessed { _ in
                        conn.cancel()
                        // 上传完成后清理临时目录（35–75MB/段，不留垃圾）
                        try? FileManager.default.removeItem(at: dir)
                        DispatchQueue.main.async { self.statusText = "采集已上传（\(total) 帧）" }
                    })
                }
                return
            }
            let pngPath = dir.appendingPathComponent(
                String(format: "frames/%04d.png", i + 1)).path
            guard let json = lines[i].data(using: .utf8),
                  let bin = FileManager.default.contents(atPath: pngPath) else {
                sendFrame(i + 1)   // 单帧缺失不阻塞整体上传
                return
            }
            send(recordData(json, bin: bin)) { sendFrame(i + 1) }
        }
        send(recordData(try! JSONSerialization.data(withJSONObject: session), bin: nil)) {
            sendFrame(0)
        }
    }

    /// 控制信道接收循环：Mac → iPhone，[4字节大端长度][JSON]，目前只有 calib 一种
    private func receiveControl(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self, let data, data.count == 4, error == nil, !isComplete else { return }
            let len = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard len > 0, len < 65_536 else { return }
            conn.receive(minimumIncompleteLength: Int(len), maximumLength: Int(len)) {
                [weak self] body, _, bodyComplete, bodyError in
                guard let self else { return }
                if let body, bodyError == nil { self.handleControl(body) }
                if bodyComplete || bodyError != nil { return }
                self.receiveControl(conn)
            }
        }
    }

    /// 解析 Mac 下发的控制消息（calib 标定表 / pairingQR 二维码可见状态）
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
}

extension CameraStreamer: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 本机识别：≥10ms 间隔逐帧识别（alwaysDiscardsLateVideoFrames 保证队列不积压），
        // 与推流/扫码互不阻塞（同队列顺序执行）
        let now0 = CFAbsoluteTimeGetCurrent()
        if now0 - lastLocalizeTime >= 0.01 {
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
