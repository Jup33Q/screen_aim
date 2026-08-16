//
//  ContentView.swift
//  AimPhone（iOS 端）— 全部 UI：相机预览、瞄准十字、亮度手势、扫码遮罩、云台 pill
//
//  关键约束：预览旋转由 RotationCoordinator 驱动（ADR-002）；太阳按钮为单一
//  DragGesture 状态机（ADR-005/006 见 docs/decisions.md）；玻璃效果走 glass* 兼容封装
//

import SwiftUI
import AVFoundation

/// 相机预览：全屏铺满；旋转角度交给 AVCaptureDevice.RotationCoordinator（iOS 17+），
/// 它以窗口场景的界面方向为准（横屏两个方向都覆盖），且自带正确的初始值——
/// 冷启动时手机固定不动（如夹在云台上）不会触发 UIDevice 方向通知，
/// 手动映射 UIDeviceOrientation 在启动瞬间拿不到可靠方向，画面就会翻转。
/// 主流模式：根层即 AVCaptureVideoPreviewLayer（layerClass 重写），
/// 由系统自动跟随 bounds 缩放，无需在 layoutSubviews 手动同步 frame
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = .black   // 首帧到达前保持纯黑而非透明
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.startRotationSync()
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // 旋转角度由 RotationCoordinator KVO 驱动，无需在此同步
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?
        private var runningObservation: NSKeyValueObservation?

        /// 从 session 的视频输入取当前采集设备（前后摄切换后自动跟随）
        private var captureDevice: AVCaptureDevice? {
            previewLayer.session?.inputs
                .compactMap { ($0 as? AVCaptureDeviceInput)?.device }
                .first { $0.hasMediaType(.video) }
        }

        /// 角度同步有三个时机缺一不可：
        /// 1. RotationCoordinator 的角度变化（旋转设备时，KVO 主线程派发）
        /// 2. session 开始运行（冷启动时 connection 在 startRunning 后才存在，
        ///    只监听角度会错过第一次赋值，画面停留在默认方向 = 横屏翻转）
        /// 3. 视图进入窗口层级（coordinator 对不在层级里的 layer 只返回 0°，
        ///    makeUIView 阶段视图尚未上屏，didMoveToWindow 里需要补一次）
        func startRotationSync() {
            guard let device = captureDevice else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device,
                                                                  previewLayer: previewLayer)
            rotationCoordinator = coordinator
            rotationObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]
            ) { [weak self] c, _ in
                let angle = c.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { self?.applyRotation(angle) }
            }
            if let session = previewLayer.session {
                runningObservation = session.observe(\.isRunning, options: [.initial, .new]) { [weak self] s, _ in
                    guard s.isRunning else { return }
                    DispatchQueue.main.async { self?.reapplyCurrentAngle() }
                }
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // 前后摄切换后采集设备变了：重建 coordinator
            if rotationCoordinator?.device !== captureDevice {
                rotationObservation = nil
                runningObservation = nil
                rotationCoordinator = nil
                startRotationSync()
            }
            reapplyCurrentAngle()
        }

        private func reapplyCurrentAngle() {
            guard let rotationCoordinator else { return }
            applyRotation(rotationCoordinator.videoRotationAngleForHorizonLevelPreview)
        }

        private func applyRotation(_ angle: Double) {
            guard let conn = previewLayer.connection,
                  conn.isVideoRotationAngleSupported(angle),
                  conn.videoRotationAngle != angle else { return }
            conn.videoRotationAngle = angle
        }
    }
}

struct ContentView: View {
    @StateObject private var streamer = CameraStreamer()
    @StateObject private var gimbal = GimbalManager()   // DockKit 云台适配（Insta360 Flow 2 Pro 等）
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("macHost") private var macHost = "192.168.1.100"
    @AppStorage("macPort") private var macPort = "9100"
    @State private var brightness: Float = 0.15   // 默认低亮度，防屏幕过曝
    @State private var dragStartBrightness: Float = 0.15
    @State private var brightnessActive = false     // 太阳按钮长按激活中（黄色高亮 + 亮度条展开）
    @State private var lastTickStep = -1            // 亮度调节触觉反馈的刻度记录
    // 太阳按钮按压状态机（单一 DragGesture 实现，避免 Tap/LongPress 手势竞争）
    @State private var pressActive = false          // 手指正按在按钮上
    @State private var pressActivated = false       // 本次按压是否已触发长按激活
    @State private var pressMoved = false           // 本次按压是否有位移
    @State private var showExitConfirm = false      // 退出应用二次确认

    /// 亮度调节触觉反馈：每跨 5% 刻度震一下
    private func tickBrightness(_ v: Float) {
        let step = Int(v * 20)
        if step != lastTickStep {
            lastTickStep = step
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    /// 状态着色：connected=绿 / transitional=橙 / error=红 / idle=灰
    private var statusColor: Color {
        if streamer.isConnected { return .green }
        if streamer.isConnecting || streamer.scanning { return .orange }
        if streamer.connectionError { return .red }
        return .secondary
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch streamer.cameraAvailability {
            case .unauthorized:
                cameraFallback(title: "无法使用相机",
                               icon: "camera.fill",
                               reason: "相机权限被拒绝，请在系统设置中允许 AimPhone 访问相机。",
                               showSettings: true)
            case .failed(let reason):
                cameraFallback(title: "相机初始化失败",
                               icon: "exclamationmark.triangle.fill",
                               reason: reason,
                               showSettings: false)
            default:
                cameraContent
            }
        }
        .persistentSystemOverlays(.hidden)   // 沉浸式全屏
        .onAppear {
            streamer.onScanned = { host, port in
                macHost = host
                macPort = String(port)
            }
            streamer.startCamera()
            // 云台按键 → App 操作（DockKit accessoryEvents，GimbalManager 只做分发）
            gimbal.onShutter = {   // 快门键：扫码配对 / 取消扫码
                if streamer.scanning { streamer.cancelScan() }
                else if !streamer.isConnected { streamer.scanQRCode() }
            }
            gimbal.onFlip = {      // 翻转键：连接（用已存地址）/ 断开
                if streamer.isConnected || streamer.isConnecting { streamer.disconnect() }
                else { streamer.connect(host: macHost, port: UInt16(macPort) ?? 9100) }
            }
            gimbal.onZoomDelta = { delta in   // 智控轮盘：增量 → 亮度（一格约 5%）
                let v = min(max(brightness + Float(delta) * 0.5, 0), 1)
                guard v != brightness else { return }
                brightness = v
                streamer.setBrightness(v)
                tickBrightness(v)
            }
            gimbal.start()
        }
        .onDisappear {
            streamer.stopCamera()
            gimbal.stop()   // 恢复系统追踪
        }
        // 退后台时停订阅并恢复系统追踪，回前台重订阅（DockKit 状态不持久）
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { gimbal.start() } else { gimbal.stop() }
        }
        // 连上（含扫码配对成功）轻触反馈
        .onChange(of: streamer.isConnected) { _, connected in
            if connected { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
        // 退出应用：二次确认（防误触），确认后直接终止进程
        .alert("退出 AimPhone？", isPresented: $showExitConfirm) {
            Button("退出", role: .destructive) { exit(0) }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 相机正常时的主界面
    private var cameraContent: some View {
        ZStack {
            // 全屏相机画面（旋转由 RotationCoordinator 跟随界面方向，画面随屏幕正立）
            CameraPreview(session: streamer.session)
                .ignoresSafeArea()

            if streamer.scanning {
                // 扫码模式：暗化遮罩 + 镂空取景框（取消走底部胶囊里的同一按钮）
                ScanOverlay()
            } else {
                // 正中心瞄准十字（不旋转）
                Crosshair()
                    .allowsHitTesting(false)
            }

            // 控件层：贴上下边，横竖屏由系统整体旋转；扫码时隐藏连接面板、保留控制胶囊
            VStack {
                if !streamer.scanning {
                    if gimbal.docked {
                        gimbalPill
                        // DEBUG: 调试面板——云台事件历史（新事件在前），定位扳机事件通道用，稳定后可移除
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(gimbal.eventHistory.prefix(8), id: \.self) { line in
                                Text(line)
                                    .lineLimit(1)
                            }
                        }
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassRounded(10)
                    }
                    controlPanel
                    // 本机识别调试 pill（iOS 端坐标转换测试：实时显示映射坐标与标记数）
                    if streamer.localMarkerCount > 0 || streamer.localAim != nil {
                        localAimPill
                    }
                }
                Spacer()
                controlCapsule
                    .padding(.bottom, 20)
            }
            .padding(.top, 8)
        }
        .animation(.easeInOut(duration: 0.2), value: streamer.scanning)
    }

    // MARK: - 太阳按钮（亮度调节入口，label 即可变 sun.max.circle，射线随亮度实时变化）
    /// 单一 DragGesture 状态机：
    /// 落指 0.35s 后仍按住 → 长按激活（中等震动 + 变黄放大 + 亮度条展开），竖拖调亮度；
    /// 激活后保持展开；短按 = 开关切换（激活态点按即复原），均带触觉反馈
    private var sunButton: some View {
        ZStack {
            // 自绘进度圆环：symbol 自带的圆圈是固定图层、不随可变值变化，
            // 用外环 trim 让圆圈随亮度条实时填充（顶端起点，顺时针）
            Circle()
                .stroke(.white.opacity(0.25), lineWidth: 2.6)
                .frame(width: 30, height: 30)
            Circle()
                .trim(from: 0, to: CGFloat(brightness))
                .stroke(brightnessActive ? Color.yellow : Color.white,
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 30, height: 30)
                .animation(.easeInOut(duration: 0.1), value: brightness)
            // 太阳图标（sun.max 不支持可变值，亮度等级由外圈进度环表达）
            Image(systemName: "sun.max")
                .font(.system(size: 19))
                .foregroundStyle(brightnessActive ? .yellow : .white)
        }
        .scaleEffect(brightnessActive ? 1.12 : 1)
        .frame(width: 44, height: 44)   // ≥44pt 点击目标
        .glassCircleNeutral()
        .contentShape(Circle())
        .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !pressActive {
                            // 落指：启动长按计时
                            pressActive = true
                            pressActivated = false
                            pressMoved = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                if pressActive && !pressActivated {
                                    pressActivated = true
                                    dragStartBrightness = brightness
                                    withAnimation(.easeInOut(duration: 0.15)) { brightnessActive = true }
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                }
                            }
                            return
                        }
                        if abs(value.translation.height) > 4 || abs(value.translation.width) > 4 {
                            pressMoved = true
                        }
                        if pressActivated {
                            // 已激活：竖拖调亮度（上增下减，260pt ≈ 全程）
                            let delta = -Float(value.translation.height) / 260
                            let v = min(max(dragStartBrightness + delta, 0), 1)
                            if v != brightness {
                                brightness = v
                                streamer.setBrightness(v)
                                tickBrightness(v)
                            }
                        }
                    }
                    .onEnded { _ in
                        pressActive = false
                        if pressActivated {
                            // 长按调节结束：保持激活态，等待下次短按复原
                            pressActivated = false
                        } else if !pressMoved {
                            // 短按：激活态 → 复原收起；未激活 → 仅轻触反馈
                            if brightnessActive {
                                withAnimation(.easeInOut(duration: 0.2)) { brightnessActive = false }
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
            )
    }

    // MARK: - 底部控制胶囊：太阳按钮 + 亮度条 + 扫码/取消按钮 同一个 capsule 容器
    private let brightnessBarWidth: CGFloat = 110

    private var controlCapsule: some View {
        HStack(spacing: 10) {
            sunButton
            // 亮度条：默认隐藏，长按太阳按钮激活后才展开；点按/横拖直接调亮度
            if brightnessActive {
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: brightnessBarWidth, height: 6)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.yellow)
                            .frame(width: brightnessBarWidth * CGFloat(brightness), height: 6)
                    }
                    .frame(height: 44)   // 扩大可触控区域到 ≥44pt
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let v = min(max(Float(value.location.x / brightnessBarWidth), 0), 1)
                                if v != brightness {
                                    brightness = v
                                    streamer.setBrightness(v)
                                    tickBrightness(v)
                                }
                            }
                    )
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .opacity))
            }

            if !streamer.isConnected {
                // 分隔线 + 扫码/取消共用按钮（扫码中变为橙色 ×）
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(width: 1.5, height: 24)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if streamer.scanning {
                        streamer.cancelScan()
                    } else {
                        streamer.scanQRCode()
                    }
                } label: {
                    Image(systemName: streamer.scanning ? "xmark" : "qrcode.viewfinder")
                        .font(.system(size: 20, weight: .semibold))
                        // 状态色只染图标前景，按钮底为透明玻璃
                        .foregroundStyle(streamer.scanning ? .orange : Color.accentColor)
                        .frame(width: 44, height: 44)   // ≥44pt 点击目标
                        .glassCircleNeutral()
                        .contentShape(Circle())
                }
                .accessibilityLabel(streamer.scanning ? "取消扫码" : "扫码配对")
            }

            // 分隔线 + Mac 配对二维码开关（同一按钮切换显示/隐藏，高亮跟随 Mac 推送的真实状态）
            Capsule()
                .fill(.white.opacity(0.3))
                .frame(width: 1.5, height: 24)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                streamer.toggleMacPairingQR()
            } label: {
                Image(systemName: "qrcode")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(!streamer.isConnected ? Color.secondary
                        : streamer.pairingQRVisibleOnMac ? .yellow : Color.accentColor)
                    .frame(width: 44, height: 44)   // ≥44pt 点击目标
                    .glassCircleNeutral()
                    .contentShape(Circle())
            }
            .accessibilityLabel("切换 Mac 配对二维码显示")

            // 分隔线 + 退出应用（红色 power，二次确认防误触）
            Capsule()
                .fill(.white.opacity(0.3))
                .frame(width: 1.5, height: 24)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showExitConfirm = true
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 44, height: 44)   // ≥44pt 点击目标
                    .glassCircleNeutral()
                    .contentShape(Circle())
            }
            .accessibilityLabel("退出应用")
        }
        .foregroundStyle(.white)
        .padding(.leading, 8)
        .padding(.trailing, streamer.isConnected ? 16 : 8)
        .padding(.vertical, 8)
        .glassCapsule()
        .animation(.easeInOut(duration: 0.2), value: brightnessActive)
    }

    // MARK: - 本机识别调试 pill（iOS 端坐标转换测试）
    /// 实时显示：本机映射的屏幕坐标（与 Mac 终端输出对照）、检出标记数、标定表来源
    private var localAimPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "viewfinder")
                .foregroundStyle(streamer.localAim != nil ? Color.green : Color.orange)
            if let aim = streamer.localAim {
                Text(String(format: "本机 (%4.0f, %4.0f)", aim.x, aim.y))
            } else {
                Text("本机识别中")
            }
            Text("标记 \(streamer.localMarkerCount)/4 · \(streamer.calibSource)")
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCapsule()
    }

    // MARK: - 相机不可用兜底（权限拒绝 / 配置失败，不再只给黑屏）
    private func cameraFallback(title: String, icon: String,
                                reason: String, showSettings: Bool) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(reason)
        } actions: {
            if showSettings {
                Button("打开设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .primaryGlassButton()
            }
        }
    }

    // MARK: - 云台状态 pill（DockKit：型号/电量 + 扳机门控的按键功能图例）
    /// 图例逻辑：scope=扳机（按住时黄色高亮），其右侧三个功能图标只在扳机按住时点亮：
    /// sun.max=轮盘调亮度 · qrcode.viewfinder=快门扫码 · link=翻转键连接/断开
    private var gimbalPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "gyroscope")
                .foregroundStyle(.green)
            Text(gimbal.accessoryModel.isEmpty ? "云台已连接" : gimbal.accessoryModel)
                .foregroundStyle(.white)
                .lineLimit(1)
            if let level = gimbal.batteryLevel {
                Image(systemName: lowBatterySymbol(level))
                    .foregroundStyle(gimbal.lowBattery ? Color.red : Color.secondary)
                Text("\(Int(level * 100))%")
                    .foregroundStyle(gimbal.lowBattery ? Color.red : Color.secondary)
            }

            Capsule().fill(.white.opacity(0.3)).frame(width: 1.5, height: 14)

            // 扳机：功能修饰键（按住时机械臂锁定）
            Image(systemName: "scope")
                .foregroundStyle(gimbal.triggerHeld ? Color.yellow : Color.secondary)
                .accessibilityLabel("扳机")
            // 功能键：扳机按住时点亮
            HStack(spacing: 6) {
                Image(systemName: "sun.max")
                    .accessibilityLabel("轮盘调亮度")
                Image(systemName: "qrcode.viewfinder")
                    .accessibilityLabel("快门键扫码")
                Image(systemName: "link")
                    .accessibilityLabel("翻转键连接或断开")
            }
            .foregroundStyle(gimbal.triggerHeld ? Color.accentColor : Color.secondary.opacity(0.6))
            .animation(.easeInOut(duration: 0.15), value: gimbal.triggerHeld)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCapsule()
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func lowBatterySymbol(_ level: Float) -> String {
        switch level {
        case ..<0.25: return "battery.25percent"
        case ..<0.5:  return "battery.50percent"
        case ..<0.75: return "battery.75percent"
        default:      return "battery.100percent"
        }
    }

    // MARK: - 顶部连接面板（已连接折叠为紧凑 pill）
    private var controlPanel: some View {
        VStack(spacing: 6) {
            if streamer.isConnected {
                // 已连接：只保留状态 + 断开入口，输入表单完全收起
                HStack(spacing: 10) {
                    Circle().fill(streamer.streamPaused ? Color.orange : Color.green).frame(width: 8, height: 8)
                    Text("\(streamer.statusText) · 已发送 \(streamer.framesSent) 帧\(streamer.streamPaused ? " · 已暂停" : "")")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(streamer.streamPaused ? .orange : .green)
                        .lineLimit(1)
                    Button("断开") { streamer.disconnect() }
                        .secondaryGlassButton()
                        .frame(minHeight: 28)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassCapsule()
            } else {
                HStack(spacing: 8) {
                    TextField("Mac IP", text: $macHost)
                        .textFieldStyle(.plain)
                        .keyboardType(.numbersAndPunctuation)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: 160)
                        .background(.clear)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.45), lineWidth: 1))
                    TextField("端口", text: $macPort)
                        .textFieldStyle(.plain)
                        .keyboardType(.numberPad)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(width: 70)
                        .background(.clear)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.45), lineWidth: 1))
                    Button {
                        if streamer.isConnecting {
                            streamer.disconnect()
                        } else {
                            streamer.connect(host: macHost,
                                             port: UInt16(macPort) ?? 9100)
                        }
                    } label: {
                        Text(streamer.isConnecting ? "取消" : "连接")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .layeredGlassCapsule(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .glassRounded(12)

                Text("\(streamer.statusText) · 帧 \(streamer.framesSeen)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassCapsule()
            }
        }
    }
}

// MARK: - Liquid Glass 兼容封装（iOS 26+ 玻璃效果，旧系统回退材质）
extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func glassRounded(_ radius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }

    @ViewBuilder
    func glassCircleNeutral() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Circle())
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
    }

    @ViewBuilder
    func primaryGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// 有层次感的玻璃胶囊：tint 玻璃主体 + 边缘描边，按钮按下有液态高光
    @ViewBuilder
    func layeredGlassCapsule(_ tint: Color) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(tint.opacity(0.6), lineWidth: 1))
        }
    }

    @ViewBuilder
    func secondaryGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// 正中心瞄准点：十字 + 圆环
struct Crosshair: View {
    var body: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            Path { p in
                let arm: CGFloat = 28, gap: CGFloat = 6
                p.move(to: CGPoint(x: c.x - arm, y: c.y)); p.addLine(to: CGPoint(x: c.x - gap, y: c.y))
                p.move(to: CGPoint(x: c.x + gap, y: c.y)); p.addLine(to: CGPoint(x: c.x + arm, y: c.y))
                p.move(to: CGPoint(x: c.x, y: c.y - arm)); p.addLine(to: CGPoint(x: c.x, y: c.y - gap))
                p.move(to: CGPoint(x: c.x, y: c.y + gap)); p.addLine(to: CGPoint(x: c.x, y: c.y + arm))
            }
            .stroke(Color.green, lineWidth: 2)
            Circle()
                .stroke(Color.green, lineWidth: 1.5)
                .frame(width: 24, height: 24)
                .position(c)
            Circle()
                .fill(Color.green)
                .frame(width: 3, height: 3)
                .position(c)
        }
    }
}

/// 扫码遮罩：全屏暗化 + 中央镂空取景框 + 四角括号 + 往复扫描线
/// （取消与扫码共用底部胶囊里的同一按钮）
struct ScanOverlay: View {
    @State private var lineDown = false
    private let size: CGFloat = 240

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(x: (geo.size.width - size) / 2,
                              y: (geo.size.height - size) / 2 - 24,
                              width: size, height: size)
            // 暗化全屏，even-odd 镂空取景框
            Color.black.opacity(0.5)
                .mask(
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: geo.size))
                        p.addRect(rect)
                    }
                    .fill(style: FillStyle(eoFill: true))
                )
            CornerBrackets()
                .stroke(Color.accentColor, lineWidth: 3)
                .frame(width: size, height: size)
                .position(x: rect.midX, y: rect.midY)
            Capsule()
                .fill(Color.accentColor.opacity(0.9))
                .frame(width: size - 40, height: 2)
                .position(x: rect.midX,
                          y: lineDown ? rect.maxY - 20 : rect.minY + 20)
            Text("对准 Mac 屏幕上的二维码")
                .font(.caption)
                .foregroundStyle(.white)
                .position(x: rect.midX, y: rect.maxY + 28)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)   // 遮罩不拦截触摸
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                lineDown = true
            }
        }
    }
}

/// 取景框四角 L 形括号（臂长 24pt，圆角 8pt）
struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let arm: CGFloat = 24, r: CGFloat = 8
        // 左上
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        // 右上
        p.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                       control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
        // 右下
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
        // 左下
        p.move(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - arm))
        return p
    }
}

#Preview {
    ContentView()
}
