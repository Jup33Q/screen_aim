//
//  main.swift
//  ScreenAim（Mac 端）— 采集/接收帧 → ArUco 检测 → 单应映射 → 瞄准坐标输出
//
//  关键约束：像素处理全部在非主线程（screenaim.* 队列）；坐标系约定见 docs/architecture.md；
//  四种运行模式互斥（--self-test / --make-markers / --calibrate / 仅采样）
//

import Foundation
import AppKit
import Network
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import OpenCVBridge
import ScreenAimCore

/// 加载图像文件为紧凑 BGRA（离线检测模式共用）
func loadBGRA(from path: String) -> (Data, Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = cg.width, h = cg.height
    var data = Data(count: w * h * 4)
    let ok = data.withUnsafeMutableBytes { ptr -> Bool in
        guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? (data, w, h) : nil
}

// MARK: - 屏幕采样器
/// 帧处理中枢：ScreenCaptureKit 采集 / JPEG 推流两条入口汇入同一检测映射管线。
///
/// 两条入口：`start()` 起 SCStream 本机采屏；`processJPEG(_:)` 由 FrameServer 喂手机帧。
/// 填好 `screenCornerMap`（≥4 个标记的屏幕坐标，冗余 8 标记见 ADR-007）后，
/// 每帧把帧中心映射到屏幕坐标并经 `onAim` 输出。
final class ScreenSampler: NSObject, SCStreamOutput {

    private var stream: SCStream?
    private var frameCount = 0
    private var fpsWindowStart = CACurrentMediaTime()
    private let bridge = OpenCVBridge()
    // Phase 0 基线测量：FPS 窗口内的检测耗时累计（processBGRA 打点，tickFPS 取均值输出）
    private var detectMsSum = 0.0
    private var detectCount = 0

    // 屏幕定位码 ID -> 屏幕坐标（左上角原点，单位：点）；≥4 项即可映射（冗余 8 标记，ADR-007）
    // dst 用什么单位，映射结果就是什么单位；homography 自动吸收采样降分辨率的比例
    var screenCornerMap: [Int32: CGPoint] = [:]

    // 检测到有效映射时回调（左上角原点，点坐标）
    var onAim: ((CGPoint) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "ScreenAim", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有可捕获的显示器（检查屏幕录制权限）"])
        }
        print("捕获显示器: \(display.width) x \(display.height)")

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // 降采样到 1280 宽，检测 ArUco 足够且省 CPU
        config.width = 1280
        config.height = 1280 * display.height / display.width
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "screenaim.sampler"))
        try await stream.startCapture()
        self.stream = stream
        print("开始采样，按 Ctrl+C 退出")
    }

    // MARK: SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        autoreleasepool { process(pixelBuffer) }
        tickFPS()
    }

    private func process(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }

        // 处理行对齐 padding：必要时逐行拷贝成紧凑数据
        let compact: Data
        if bytesPerRow == w * 4 {
            compact = Data(bytes: base, count: h * bytesPerRow)
        } else {
            var buf = Data(count: w * h * 4)
            buf.withUnsafeMutableBytes { dst in
                for row in 0..<h {
                    memcpy(dst.baseAddress!.advanced(by: row * w * 4),
                           base.advanced(by: row * bytesPerRow), w * 4)
                }
            }
            compact = buf
        }
        processBGRA(compact, width: w, height: h)
    }

    /// 解码 JPEG 帧（手机推流模式）并处理
    func processJPEG(_ jpeg: Data) {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        let w = cg.width, h = cg.height
        var data = Data(count: w * h * 4)
        data.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                  | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        processBGRA(data, width: w, height: h)
        tickFPS()
    }

    /// 核心处理：紧凑 BGRA 帧 → ArUco 检测 → 匹配 ≥4 个标记时 RANSAC 单应映射帧中心。
    /// - Parameters:
    ///   - compact: 无行 padding 的 BGRA 数据（`process(_:)` 已处理对齐）
    ///   - w / h: 帧像素尺寸
    /// 映射结果单位与 `screenCornerMap` 一致（屏幕点坐标，左上角原点）。
    func processBGRA(_ compact: Data, width w: Int, height h: Int) {

        let t0 = CACurrentMediaTime()
        let markers = compact.withUnsafeBytes { ptr -> [ArucoMarker] in
            bridge.detectMarkers(inBGRABuffer: ptr.baseAddress!, width: Int32(w), height: Int32(h))
        }
        // 检测耗时打点（Phase 0）：与帧率同窗口平均，FPS 日志行输出 det=xxms
        detectMsSum += (CACurrentMediaTime() - t0) * 1000
        detectCount += 1

        for m in markers {
            print(String(format: "marker id=%d center=(%.1f, %.1f)",
                         m.markerId, m.center.x, m.center.y))
        }

        // 匹配 ≥4 个已知标记 -> RANSAC 单应 -> 帧中心(瞄准点)映射到屏幕坐标（ADR-007：
        // 任一角被遮挡或单帧掉检时仍有输出，RANSAC 剔除个别错位点）
        guard screenCornerMap.count >= 4 else { return }
        var src: [NSValue] = []
        var dst: [NSValue] = []
        for m in markers {
            guard let screenPt = screenCornerMap[Int32(m.markerId)] else { continue }
            src.append(NSValue(point: m.center))
            dst.append(NSValue(point: screenPt))
        }
        guard src.count >= 4 else { return }

        var ok = ObjCBool(false)
        // 帧中心 = 瞄准点；结果单位与 screenCornerMap 一致（点坐标，左上角原点）
        let mapped = OpenCVBridge.mapPointRANSAC(CGPoint(x: w / 2, y: h / 2),
                                                 srcPoints: src, dstPoints: dst,
                                                 success: &ok)
        if ok.boolValue {
            print(String(format: "瞄准点 -> 屏幕坐标 (%.0f, %.0f)", mapped.x, mapped.y))
            onAim?(mapped)
        }
    }

    private func tickFPS() {
        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - fpsWindowStart
        if elapsed >= 2.0 {
            let detAvg = detectCount > 0 ? detectMsSum / Double(detectCount) : 0
            print(String(format: "FPS: %.1f det=%.1fms", Double(frameCount) / elapsed, detAvg))
            frameCount = 0
            fpsWindowStart = now
            detectMsSum = 0
            detectCount = 0
        }
    }
}

// MARK: - 二维码配对
/// 本机主网卡 IPv4（优先 en0）
func primaryIPv4() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    defer { freeifaddrs(ifaddr) }
    var fallback: String?
    var ptr = ifaddr
    while let a = ptr {
        defer { ptr = a.pointee.ifa_next }
        guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: a.pointee.ifa_name)
        var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
        let ip = String(cString: buf)
        if name == "en0" { return ip }
        if !ip.hasPrefix("127."), fallback == nil { fallback = ip }
    }
    return fallback
}

/// 生成二维码 NSImage
func makeQRImage(_ string: String, side: CGFloat) -> NSImage? {
    guard let data = string.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let ci = filter.outputImage else { return nil }
    let scale = side / ci.extent.width
    let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let rep = NSCIImageRep(ciImage: scaled)
    let img = NSImage(size: NSSize(width: side, height: side))
    img.addRepresentation(rep)
    return img
}

/// 生成小程序码风格的圆点二维码：
/// 数据模块画成圆点，三个定位角保持实心圆角方块（保证识别率），白色底
func makeStyledQRImage(_ string: String, side: CGFloat) -> NSImage? {
    guard let data = string.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let ci = filter.outputImage,
          let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }

    // CIQRCodeGenerator 输出恰好 1px = 1 模块，逐像素取样得到模块矩阵
    let modules = cg.width
    var pixels = [UInt8](repeating: 255, count: modules * modules * 4)
    guard let ctx = CGContext(data: &pixels, width: modules, height: modules,
                              bitsPerComponent: 8, bytesPerRow: modules * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: modules, height: modules))

    func isDark(_ mx: Int, _ my: Int) -> Bool {   // my 从顶部数
        pixels[((modules - 1 - my) * modules + mx) * 4] < 128
    }
    func inFinder(_ mx: Int, _ my: Int) -> Bool {  // 三个 7x7 定位角
        (mx < 7 && my < 7) || (mx >= modules - 7 && my < 7) || (mx < 7 && my >= modules - 7)
    }

    return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        NSColor.white.setFill()
        rect.fill()
        NSColor.black.setFill()
        let cell = side / CGFloat(modules)
        for my in 0..<modules {
            for mx in 0..<modules where isDark(mx, my) {
                let r = CGRect(x: CGFloat(mx) * cell,
                               y: rect.height - CGFloat(my + 1) * cell,
                               width: cell, height: cell)
                if inFinder(mx, my) {
                    NSBezierPath(roundedRect: r, xRadius: cell * 0.25, yRadius: cell * 0.25).fill()
                } else {
                    NSBezierPath(ovalIn: r.insetBy(dx: cell * 0.06, dy: cell * 0.06)).fill()
                }
            }
        }
        return true
    }
}

/// 从 CIQRCodeGenerator 提取模块矩阵：返回值 dark[my*modules+mx] = 该模块是否为黑（my 从顶部数，不含静区）
func qrModuleMatrix(_ string: String) -> (modules: Int, dark: [Bool])? {
    guard let data = string.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let ci = filter.outputImage,
          let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
    let modules = cg.width
    var pixels = [UInt8](repeating: 255, count: modules * modules * 4)
    guard let ctx = CGContext(data: &pixels, width: modules, height: modules,
                              bitsPerComponent: 8, bytesPerRow: modules * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: modules, height: modules))
    var dark = [Bool](repeating: false, count: modules * modules)
    for my in 0..<modules {           // my 从顶部数；位图行 0 是底部，需翻转
        for mx in 0..<modules {
            dark[my * modules + mx] = pixels[((modules - 1 - my) * modules + mx) * 4] < 128
        }
    }
    return (modules, dark)
}

/// 把模块矩阵渲染成 mask 位图（模块存在处 alpha=255，其余透明），供 CALayer.mask 使用。
/// WARNING: CALayer.mask 取的是 alpha 通道，必须用带 alpha 的位图——无 alpha 的灰度图会被当作全不透明。
func qrMaskCGImage(modules: Int, bits: [Bool], scale: Int) -> CGImage? {
    let side = modules * scale
    var buf = [UInt8](repeating: 0, count: side * side * 4)
    guard let ctx = CGContext(data: &buf, width: side, height: side,
                              bitsPerComponent: 8, bytesPerRow: side * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    for my in 0..<modules {
        for mx in 0..<modules where bits[my * modules + mx] {
            // CGContext 左下原点：my（顶部起）翻转到 y
            ctx.fill(CGRect(x: mx * scale, y: (modules - 1 - my) * scale,
                            width: scale, height: scale))
        }
    }
    return ctx.makeImage()
}

/// macOS 26+：双折射率 Liquid Glass 二维码。
/// 黑模块 = regular 玻璃（强折射）+ 黑 tint，白模块 = clear 玻璃（弱折射）+ 白 tint，
/// 各用模块位图做 CALayer mask，叠出黑白区分。返回覆盖 qrSide 方块的容器视图。
@available(macOS 26.0, *)
func makeGlassQRView(payload: String, side: CGFloat) -> NSView? {
    guard let (modules, dark) = qrModuleMatrix(payload) else { return nil }
    var light = [Bool](repeating: true, count: modules * modules)
    for i in 0..<light.count { light[i] = !dark[i] }
    let scale = 16
    guard let darkMask = qrMaskCGImage(modules: modules, bits: dark, scale: scale),
          let lightMask = qrMaskCGImage(modules: modules, bits: light, scale: scale)
    else { return nil }

    let host = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
    host.wantsLayer = true

    // 白模块层（clear 玻璃 = 弱折射，亮）
    // NOTE: mask 必须加在父容器上——玻璃渲染在私有效果层，mask 自己的 layer 裁不到
    let lightWrap = NSView(frame: host.bounds)
    lightWrap.wantsLayer = true
    let lightMaskLayer = CALayer()
    lightMaskLayer.frame = lightWrap.bounds
    lightMaskLayer.contents = lightMask
    lightWrap.layer?.mask = lightMaskLayer
    let lightGlass = NSGlassEffectView(frame: lightWrap.bounds)
    lightGlass.style = .clear
    lightGlass.cornerRadius = side * 0.06
    lightGlass.tintColor = NSColor.white.withAlphaComponent(0.85)
    lightWrap.addSubview(lightGlass)
    host.addSubview(lightWrap)

    // 黑模块层（regular 玻璃 = 强折射，暗）
    let darkWrap = NSView(frame: host.bounds)
    darkWrap.wantsLayer = true
    let darkMaskLayer = CALayer()
    darkMaskLayer.frame = darkWrap.bounds
    darkMaskLayer.contents = darkMask
    darkWrap.layer?.mask = darkMaskLayer
    let darkGlass = NSGlassEffectView(frame: darkWrap.bounds)
    darkGlass.style = .regular
    darkGlass.cornerRadius = side * 0.06
    darkGlass.tintColor = NSColor.black.withAlphaComponent(0.72)
    darkWrap.addSubview(darkGlass)
    host.addSubview(darkWrap)
    return host
}

/// 闭包驱动的滑杆（标定层顶部面板里实时调定位码大小用）
final class ActionSlider: NSSlider {
    var onChange: ((Double) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(changed)
        isContinuous = true
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func changed() { onChange?(doubleValue) }
}

/// 定位码尺寸徽章：ZStack 语义 = 底层 SF Symbol 可变圆环（variable circle，
/// 进度弧随 pt 值填充）+ 上层数值文本
final class SizeBadgeView: NSView {
    var value: Int = 16 { didSet { update() } }
    private let minV = 16.0, maxV = 96.0
    private let ringView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        ringView.contentTintColor = .white
        ringView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(ringView)
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
        ringView.frame = bounds.insetBy(dx: 2, dy: 2)
        centerLabel()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        ringView.frame = bounds.insetBy(dx: 2, dy: 2)
        centerLabel()
    }

    /// NSTextField 的 cell 不按 frame 垂直居中，需 sizeToFit 后手动居中
    private func centerLabel() {
        label.sizeToFit()
        let s = label.frame.size
        label.frame = NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2,
                             width: s.width, height: s.height)
    }

    private func update() {
        let t = (Double(value) - minV) / (maxV - minV)
        ringView.image = NSImage(systemSymbolName: "circle", variableValue: t,
                                 accessibilityDescription: "定位码边长")
        label.stringValue = "\(value)"
        centerLabel()
    }
}

/// 闭包驱动的按钮（NSPanel 里的配对码开关用）
final class ActionButton: NSButton {
    var onClick: (() -> Void)?
    /// 触控板悬停触觉反馈开关（Force Touch 触控板才有实体震感）
    var hoverHaptics = true
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(clicked)
        isBordered = false
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func clicked() { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // 悬停时给触控板一次轻微敲击反馈（不支持 Force Touch 的硬件上系统自动忽略）
        guard hoverHaptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

// MARK: - TCP 帧服务（手机推流模式）
/// 手机 JPEG 推流服务：NWListener + Bonjour 自动发现。
///
/// 线上协议：`[4 字节大端长度][JPEG 数据]` 循环往复，单帧上限 16 MB（见 docs/protocol.md）。
/// 读循环：`readHeader`（首次，含 `conn.start`）→ `readBody` → `readBody0`（后续帧头，不重复 start）。
final class FrameServer {
    let port: UInt16
    let onFrame: (Data) -> Void
    var onConnect: (() -> Void)?      // 手机连上时回调（用于隐藏配对二维码）
    /// 新连接建立后立刻下发一次的控制消息（标定映射表，protocol.md §6）；nil 则不发
    var handshakePayload: (() -> Data?)?
    /// 手机端控制消息回调（长度字最高位置位的帧，protocol.md §7），参数为 JSON 对象
    var onControl: (([String: Any]) -> Void)?
    /// 监听器失败回调（主线程）。NOTE: EADDRINUSE 等绑定失败是异步经 stateUpdateHandler
    /// 上报的，start() 的 throw 捕不到；不处理的话 App 会继续显示配对二维码，
    /// 但扫码连的是占端口的老进程——屏幕上留下永远配不对的"僵尸二维码"
    var onListenerFailed: ((Error) -> Void)?
    private var listener: NWListener?
    private var activeConns: [NWConnection] = []   // 存活连接（状态广播用，断开时移除）

    init(port: UInt16, onFrame: @escaping (Data) -> Void) {
        self.port = port
        self.onFrame = onFrame
    }

    func start() throws {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "ScreenAim", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "非法端口 \(port)"])
        }
        let l = try NWListener(using: .tcp, on: p)
        // Bonjour 广播：手机端无需知道 IP，自动发现自动连接
        l.service = NWListener.Service(name: "AimPhone-Mac", type: "_aimphone._tcp")
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            print("手机已连接: \(conn.endpoint)")
            self.activeConns.append(conn)
            DispatchQueue.main.async { self.onConnect?() }
            self.readHeader(conn)   // 内含 conn.start
            // 控制信道：连接建立即下发标定映射表（[4B 大端长度][JSON]）
            if let data = self.handshakePayload?() {
                var len = UInt32(data.count).bigEndian
                conn.send(content: withUnsafeBytes(of: &len) { Data($0) } + data,
                          completion: .idempotent)
                print("标定映射表已下发（\(data.count) 字节）")
            }
        }
        l.stateUpdateHandler = { [weak self] st in
            print("帧服务状态: \(st)")
            if case .failed(let e) = st {
                DispatchQueue.main.async { self?.onListenerFailed?(e) }
            }
        }
        l.start(queue: DispatchQueue(label: "screenaim.server"))
        listener = l
        print("TCP 帧服务已启动，端口 \(port)，等待手机连接…")
    }

    /// 向所有存活连接广播控制消息（Mac → iPhone，[4B 大端长度][JSON]，protocol.md §6）
    func sendControl(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var len = UInt32(data.count).bigEndian
        let header = withUnsafeBytes(of: &len) { Data($0) }
        for conn in activeConns {
            conn.send(content: header + data, completion: .idempotent)
        }
    }

    /// 连接终结点统一清理（receive 失败/完成时调用）
    private func drop(_ conn: NWConnection) {
        activeConns.removeAll { $0 === conn }
        conn.cancel()
    }

    private func readHeader(_ conn: NWConnection) {
        conn.start(queue: DispatchQueue(label: "screenaim.conn"))
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self, let data, data.count == 4, error == nil, !isComplete else {
                self?.drop(conn); return
            }
            let raw = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let isControl = raw & 0x8000_0000 != 0   // 最高位：1=控制帧(JSON) 0=视频帧(JPEG)
            let len = raw & 0x7FFF_FFFF
            guard len > 0, len < 16_000_000 else { self.drop(conn); return }
            self.readBody(conn, length: Int(len), isControl: isControl)
        }
    }

    private func readBody(_ conn: NWConnection, length: Int, isControl: Bool) {
        conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            if let data, error == nil {
                if isControl {
                    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.onControl?(obj)
                    }
                } else {
                    self.onFrame(data)
                }
            }
            if isComplete || error != nil { self.drop(conn); return }
            self.readBody0(conn)
        }
    }

    // 继续读下一帧头（连接已 start，无需重复 start）
    private func readBody0(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self, let data, data.count == 4, error == nil, !isComplete else {
                self?.drop(conn); return
            }
            let raw = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let isControl = raw & 0x8000_0000 != 0
            let len = raw & 0x7FFF_FFFF
            guard len > 0, len < 16_000_000 else { self.drop(conn); return }
            self.readBody(conn, length: Int(len), isControl: isControl)
        }
    }
}

// MARK: - 透明悬浮标定层
/// 全屏透明、点击穿透的悬浮窗口：四角 + 四边中点共 8 个悬浮 ArUco 标记（ADR-007）
/// +（推流模式）中央配对二维码。
///
/// - 每个标记自带白色圆角底卡，保证任意桌面背景下的 ArUco 静区（WARNING: 无静区无法检测）
/// - 标记中心坐标自动写入 `ScreenSampler.screenCornerMap`，无需手工标定
/// - 配对二维码内容 `{"host":ip,"port":port}`，IP 每 5 秒轮询、变化即重生成
/// - `run()` 阻塞进 NSApp 主循环，ESC 退出
final class Calibrator: NSObject {
    var markerSize: CGFloat   // 标记边长（点），滑杆实时调整
    let inset: CGFloat        // 标记中心距屏幕边缘的距离（点）
    let pad: CGFloat          // 白卡内边距（点），保证静区
    let servePort: UInt16?    // 非 nil：手机推流模式（不采本机屏幕）
    var window: NSWindow?
    var qrCard: NSView?       // 配对二维码卡片（连接成功后隐藏）
    var qrHost: NSView?       // 二维码视觉容器（玻璃模块层 / 位图回退都加在这里）
    /// 立即按当前 IP 重新生成配对二维码（IP 看守计时器与手机断开通知共用）
    var refreshQRNow: (() -> Void)?
    var qrButton: ActionButton?  // Mac 端配对码开关按钮（悬浮 NSPanel 上）
    var currentPayload = ""
    var debugLabel: NSTextField?  // 手机端本机识别结果（localAim）的悬浮 debug 文本
    var centers: [CGPoint] = []        // 当前 8 个标记中心的屏幕点坐标（左上角原点）
    var markerCards: [NSView] = []     // 当前 8 块白卡视图（rebuildMarkers 重建）
    var screenW: CGFloat = 0           // 屏幕点尺寸（calib 负载用）
    var screenH: CGFloat = 0

    // localAim 结构化日志：每条上报追加一行 CSV（时间戳/检出数/坐标），供离线分析手机端识别质量
    private let csvLock = NSLock()
    private var csvHandle: FileHandle?
    private let csvStamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")

    /// 追加一条 localAim 记录到 scenes/localaim_<会话时间>.csv（onControl 在 conn 队列，加锁串行化）。
    /// 列：timestamp,markers,ids,x,y,detect_ms,src。ids 为本帧检出的标记 ID（如 "0|2"），
    /// 缺失的标记 = 全集减去该集合；detect_ms 为上报端检测耗时（旧客户端无此字段时为 0）；
    /// src 为数据来源通道（目前恒为 tcp；Phase 3 会新增 udp），离线分析用
    func logLocalAim(markers n: Int, ids: [Int], x: Double?, y: Double?,
                     detectMs: Double, src: String) {
        csvLock.lock(); defer { csvLock.unlock() }
        if csvHandle == nil {
            let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("scenes", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("localaim_\(csvStamp).csv")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path,
                                               contents: "timestamp,markers,ids,x,y,detect_ms,src\n".data(using: .utf8))
            }
            csvHandle = FileHandle(forWritingAtPath: url.path)
            csvHandle?.seekToEndOfFile()
            if csvHandle != nil { print("localAim 日志: \(url.path)") }
        }
        let xy: String = (x != nil && y != nil) ? String(format: "%.1f,%.1f", x!, y!) : ","
        let idStr = ids.map(String.init).joined(separator: "|")
        let row = String(format: "%.3f,%d,%@,%@,%.1f,%@\n",
                         Date().timeIntervalSince1970, n, idStr, xy, detectMs, src)
        if let data = row.data(using: .utf8) { csvHandle?.write(data) }
    }

    /// 重建配对二维码视觉：macOS 26+ 用双折射率 Liquid Glass 模块层，旧系统回退位图
    func rebuildQR(payload: String, side: CGFloat) {
        guard let host = qrHost else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        if #available(macOS 26.0, *),
           let glass = makeGlassQRView(payload: payload, side: side) {
            host.addSubview(glass)
        } else if let img = makeQRImage(payload, side: side) {
            let iv = NSImageView(frame: host.bounds)
            iv.image = img
            iv.imageScaling = .scaleAxesIndependently
            host.addSubview(iv)
        }
    }

    /// 按当前 markerSize 重建标记（白卡 + ArUco 位图），并刷新 centers。
    /// 布局：四角 id0–3 + 四边中点 id4–7（冗余 8 标记，ADR-007），任取检出 ≥4 个即可建单应。
    /// 滑杆实时调整时调用；先生成全部位图再替换视图，避免中间态缺角。
    @discardableResult
    func rebuildMarkers(in content: NSView, screen: NSScreen) -> [CGPoint] {
        let W = screen.frame.width, H = screen.frame.height
        let s = markerSize, m = inset
        let card = s + pad * 2                // 白卡边长
        let newCenters: [CGPoint] = [
            CGPoint(x: m + s / 2, y: m + s / 2),            // 0 左上
            CGPoint(x: W - m - s / 2, y: m + s / 2),        // 1 右上
            CGPoint(x: W - m - s / 2, y: H - m - s / 2),    // 2 右下
            CGPoint(x: m + s / 2, y: H - m - s / 2),        // 3 左下
            CGPoint(x: W / 2, y: m + s / 2),                // 4 上中
            CGPoint(x: W - m - s / 2, y: H / 2),            // 5 右中
            CGPoint(x: W / 2, y: H - m - s / 2),            // 6 下中
            CGPoint(x: m + s / 2, y: H / 2),                // 7 左中
        ]
        // 按 Retina 物理像素生成，保证小尺寸下边缘锐利
        let px = Int32((s * screen.backingScaleFactor).rounded())
        var images: [NSImage] = []
        for id in 0..<8 {
            guard let png = OpenCVBridge.markerPNG(withId: Int32(id), sidePixels: px),
                  let img = NSImage(data: png) else { return centers }  // 生成失败则保留旧标记
            images.append(img)
        }
        markerCards.forEach { $0.removeFromSuperview() }
        markerCards.removeAll()
        for (id, c) in newCenters.enumerated() {
            // 白色底卡（圆角），保证任意桌面背景下的静区
            // WARNING: NSView 坐标是左下角原点，屏幕点坐标（左上原点）需用 H - y 翻转
            let cardView = NSView(frame: NSRect(x: c.x - card / 2, y: H - c.y - card / 2,
                                                width: card, height: card))
            cardView.wantsLayer = true
            cardView.layer?.backgroundColor = NSColor.white.cgColor
            cardView.layer?.cornerRadius = 4
            content.addSubview(cardView)
            let iv = NSImageView(frame: NSRect(x: pad, y: pad, width: s, height: s))
            iv.image = images[id]
            iv.imageScaling = .scaleAxesIndependently
            cardView.addSubview(iv)
            markerCards.append(cardView)
        }
        centers = newCenters
        return centers
    }

    /// 当前标定映射表的 calib 控制帧（protocol.md §6）：握手下发与滑杆调整后广播共用。
    /// markers 与 centers 同源（8 项：4 角 + 4 边中点），协议格式不变只扩条目
    func calibPayload() -> Data? {
        guard centers.count == 8 else { return nil }
        var markers: [String: [Double]] = [:]
        for (i, c) in centers.enumerated() {
            markers["\(i)"] = [Double(c.x), Double(c.y)]
        }
        let payload: [String: Any] = [
            "type": "calib",
            "screenW": Double(screenW), "screenH": Double(screenH),
            "markers": markers,
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    init(markerSize: CGFloat, inset: CGFloat, pad: CGFloat = 8, servePort: UInt16? = nil) {
        self.markerSize = markerSize
        self.inset = inset
        self.pad = pad
        self.servePort = servePort
    }

    func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // 不占 Dock
        guard let screen = NSScreen.main else {
            fputs("错误: 无可用屏幕\n", stderr)
            exit(1)
        }
        let f = screen.frame
        let win = NSWindow(contentRect: f, styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 1)
        win.backgroundColor = .clear          // 透明背景
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = true         // 点击穿透
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let W = f.width, H = f.height
        screenW = W; screenH = H
        // 8 个定位码（白色底卡 + ArUco 位图）；rebuildMarkers 同时刷新 self.centers
        if let content = win.contentView {
            rebuildMarkers(in: content, screen: screen)
        }
        let centers = self.centers
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window = win
        // 配对二维码（仅手机推流模式）：圆角方形卡，屏幕正中央，手机扫码自动获取 IP/端口
        if let port = servePort, let ip = primaryIPv4() {
            let payload = "{\"host\":\"\(ip)\",\"port\":\(port)}"
            let qrSide: CGFloat = 190
            let cardSide: CGFloat = 250
            let card = NSView(frame: NSRect(x: (W - cardSide) / 2, y: (H - cardSide) / 2,
                                            width: cardSide, height: cardSide))
            card.wantsLayer = true
            card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.32).cgColor
            card.layer?.cornerRadius = 26                    // 圆角方形
            card.layer?.shadowColor = NSColor.black.cgColor
            card.layer?.shadowOpacity = 0.25
            card.layer?.shadowRadius = 12
            card.layer?.shadowOffset = .zero
            let host = NSView(frame: NSRect(x: (cardSide - qrSide) / 2,
                                            y: (cardSide - qrSide) / 2,
                                            width: qrSide, height: qrSide))
            card.addSubview(host)
            qrHost = host
            rebuildQR(payload: payload, side: qrSide)
            win.contentView?.addSubview(card)
            qrCard = card
            currentPayload = payload
            print("配对信息: \(payload)")

            // IP 变化看守：每 5 秒检查一次，IP 变了自动重新生成二维码
            refreshQRNow = { [weak self] in
                guard let self, let ip = primaryIPv4() else { return }
                let newPayload = "{\"host\":\"\(ip)\",\"port\":\(port)}"
                guard newPayload != self.currentPayload else { return }
                self.currentPayload = newPayload
                self.rebuildQR(payload: newPayload, side: qrSide)
                print("IP 已变化，二维码已更新: \(newPayload)")
            }
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.refreshQRNow?()
            }
        }

        // ESC 退出（本窗口成为 key 或全局都监听）
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            if ev.keyCode == 53 { NSApp.terminate(nil) }
            return ev
        }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { ev in
            if ev.keyCode == 53 { NSApp.terminate(nil) }
        }

        // 采样器：dst 直接用标记中心的屏幕点坐标（左上角原点），8 项全量（ADR-007）
        let sampler = ScreenSampler()
        sampler.screenCornerMap = Dictionary(uniqueKeysWithValues:
            centers.enumerated().map { (Int32($0.offset), $0.element) })
        if let port = servePort {
            // 手机推流模式：TCP 收 JPEG 帧 -> 检测
            do {
                // DEBUG: 手机端本机识别结果悬浮标签（屏幕底部居中胶囊，点击穿透跟随主覆盖层）
                let dbgW: CGFloat = 380, dbgH: CGFloat = 30
                let dbgBg = NSView(frame: NSRect(x: W / 2 - dbgW / 2, y: 24,
                                                 width: dbgW, height: dbgH))
                dbgBg.wantsLayer = true
                dbgBg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
                dbgBg.layer?.cornerRadius = dbgH / 2
                let dbg = NSTextField(labelWithString: "iPhone 瞄准: 等待数据…")
                dbg.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
                dbg.textColor = .white
                dbg.alignment = .center
                dbg.frame = dbgBg.bounds
                dbgBg.addSubview(dbg)
                win.contentView?.addSubview(dbgBg)
                debugLabel = dbg

                let server = FrameServer(port: port) { [sampler] jpeg in
                    sampler.processJPEG(jpeg)
                }
                // 标定映射表下发：手机本机识别测试用，内容与 screenCornerMap 同源；
                // 滑杆调整标记大小后 centers 会变，这里始终读最新值
                server.handshakePayload = { [weak self] in
                    self?.calibPayload()
                }
                // 配对二维码可见性：任何变化都同步推送给所有已连手机（按钮高亮跟随真实状态）
                let setQRVisible: (Bool) -> Void = { [weak self] visible in
                    guard let self, let card = self.qrCard, card.isHidden == visible else { return }
                    card.isHidden = !visible
                    // 图标态：白 = 二维码可见，灰 = 已隐藏
                    self.qrButton?.contentTintColor = visible ? .white : NSColor.white.withAlphaComponent(0.4)
                    server.sendControl(["type": "pairingQR", "visible": visible])
                    print(visible ? "配对二维码已显示" : "配对二维码已隐藏")
                }
                server.onConnect = {
                    setQRVisible(false)   // 配对成功，隐藏二维码并广播状态
                }

                // Mac 端配对码开关 + 退出应用按钮 + 定位码大小滑杆：主覆盖层点击穿透，
                // 所以单独用一个可点击的悬浮 NSPanel（屏幕顶部居中）
                let qrBtnW: CGFloat = 52, closeBtnW: CGFloat = 52, btnGap: CGFloat = 8
                let sliderW: CGFloat = 210   // 滑杆胶囊（滑杆 + 数值标签）
                let panelH: CGFloat = 44
                let panelW = qrBtnW + closeBtnW + btnGap * 2 + sliderW
                // 避开刘海/菜单栏安全区：面板贴在安全区下沿再留 8pt
                let safeTop = screen.safeAreaInsets.top
                let btnPanel = NSPanel(contentRect: NSRect(x: W / 2 - panelW / 2,
                                                           y: H - safeTop - panelH - 8,
                                                           width: panelW, height: panelH),
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
                btnPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
                btnPanel.isOpaque = false
                btnPanel.backgroundColor = .clear
                btnPanel.hasShadow = false
                btnPanel.collectionBehavior = [.canJoinAllSpaces, .stationary]
                // 每个按钮各一块胶囊底卡
                func makeBtnBg(x: CGFloat, w: CGFloat) -> NSView {
                    let bg = NSView(frame: NSRect(x: x, y: 0, width: w, height: panelH))
                    bg.wantsLayer = true
                    bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
                    bg.layer?.cornerRadius = panelH / 2
                    btnPanel.contentView?.addSubview(bg)
                    return bg
                }
                // SF Symbol 图标按钮（无文字）
                func makeSymbolButton(symbol: String, tint: NSColor, tooltip: String,
                                      bg: NSView) -> ActionButton {
                    let b = ActionButton(frame: bg.bounds)
                    let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
                    b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
                        .withSymbolConfiguration(cfg)
                    b.title = ""
                    b.imagePosition = .imageOnly
                    b.contentTintColor = tint
                    b.toolTip = tooltip
                    bg.addSubview(b)
                    return b
                }
                let btnBg = makeBtnBg(x: 0, w: qrBtnW)
                let closeBg = makeBtnBg(x: qrBtnW + btnGap, w: closeBtnW)
                let btn = makeSymbolButton(symbol: "qrcode", tint: .white,
                                           tooltip: "显示 / 隐藏配对二维码", bg: btnBg)
                btn.onClick = { [weak self] in
                    setQRVisible(self?.qrCard?.isHidden ?? false)
                }
                qrButton = btn
                // 退出应用按钮：与 ESC 键同效，结束本进程
                let closeBtn = makeSymbolButton(symbol: "power", tint: .systemRed,
                                                tooltip: "退出应用", bg: closeBg)
                closeBtn.onClick = {
                    NSApp.terminate(nil)
                }
                // 定位码大小滑杆：拖动实时重建四角标记、更新 Mac 端映射表并把新标定表广播给已连手机。
                // 触控板触觉反馈：每跨 1pt 一次 .generic 轻敲；吸附档位（24/48/64/96）命中时一次
                // .alignment 对位震感（不支持 Force Touch 的硬件系统自动忽略）
                let sliderBg = makeBtnBg(x: qrBtnW + closeBtnW + btnGap * 2, w: sliderW)
                let slider = ActionSlider(frame: NSRect(x: 10, y: 8, width: 132, height: 28))
                slider.minValue = 16
                slider.maxValue = 96
                slider.doubleValue = Double(markerSize)
                slider.toolTip = "定位码边长（16–96pt）：识别不稳就往大调"
                sliderBg.addSubview(slider)
                // 滑杆右侧：数值文本 + 可变圆环（圆随 pt 值缩放），直观表达当前定位码大小
                let sizeBadge = SizeBadgeView(frame: NSRect(x: 148, y: 0, width: sliderW - 148 - 8, height: panelH))
                sizeBadge.value = Int(markerSize)
                sizeBadge.toolTip = "定位码边长（16–96pt）：识别不稳就往大调"
                sliderBg.addSubview(sizeBadge)
                let detents: [Double] = [24, 48, 64, 96]
                var lastTick = Int(markerSize)
                var lastDetent = detents.contains(Double(markerSize)) ? Int(markerSize) : -1
                slider.onChange = { [weak self] v in
                    guard let self else { return }
                    // 吸附：距档位 ≤2pt 时吸到档位
                    var snapped = v
                    var hitDetent = -1
                    for d in detents where abs(v - d) <= 2 { snapped = d; hitDetent = Int(d) }
                    let tick = Int(snapped.rounded())   // 1pt 粒度
                    if tick != lastTick {
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                        lastTick = tick
                    }
                    if hitDetent >= 0 && hitDetent != lastDetent {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                    lastDetent = hitDetent
                    guard CGFloat(tick) != self.markerSize else { return }
                    self.markerSize = CGFloat(tick)
                    if let content = win.contentView {
                        self.rebuildMarkers(in: content, screen: screen)
                    }
                    sampler.screenCornerMap = Dictionary(uniqueKeysWithValues:
                        self.centers.enumerated().map { (Int32($0.offset), $0.element) })
                    if let data = self.calibPayload(),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        server.sendControl(obj)   // 广播新标定表给所有已连手机（protocol.md §7）
                    }
                    sizeBadge.value = tick
                    print("定位码大小: \(tick)pt（滑杆调整，新标定表已广播）")
                }
                btnPanel.orderFrontRegardless()
                objc_setAssociatedObject(win, "btnPanel", btnPanel, .OBJC_ASSOCIATION_RETAIN)
                // 手机端控制消息（protocol.md §7/§8）：配对二维码开关 / 本机识别结果上报 / 鼠标模拟器
                server.onControl = { [weak self] msg in
                    switch msg["type"] as? String {
                    case "mouseClick":
                        // 横屏鼠标模拟器（§8）：在当前光标位置点击（需辅助功能权限）
                        guard let button = msg["button"] as? String else { break }
                        postMouseClick(button)
                        print("MOUSE click: \(button)")
                    case "mouseScroll":
                        // 横屏鼠标模拟器（§8）：滚轮刻度，正 = 向上滚
                        let delta = msg["delta"] as? Int ?? 0
                        if delta != 0 {
                            postMouseScroll(delta)
                            print("MOUSE scroll: \(delta)")
                        }
                    case "togglePairingQR":
                        DispatchQueue.main.async {
                            setQRVisible(self?.qrCard?.isHidden ?? false)
                        }
                    case "disconnect":
                        // 手机主动断开（protocol.md §7）：立即把二维码刷新为当前 IP 并重新显示，等待下一次配对
                        print("手机已断开，重新显示配对二维码")
                        DispatchQueue.main.async {
                            self?.refreshQRNow?()
                            setQRVisible(true)
                        }
                    case "localAim":
                        // DEBUG: 手机本机识别结果（含各标记识别状态 detected/missing），
                        // 与 Mac 端管线输出对照验证一致性；全部上报追加到 scenes/localaim_*.csv 供离线分析
                        let n = msg["markers"] as? Int ?? 0
                        // 兼容旧客户端：无 detected 字段时按数量退化为空集合；无 detect_ms 时记 0
                        let detected = (msg["detected"] as? [Int]) ?? []
                        let missing = (msg["missing"] as? [Int]) ?? (0...7).filter { !detected.contains($0) }
                        let detMs = msg["detect_ms"] as? Double ?? 0
                        if let x = msg["x"] as? Double, let y = msg["y"] as? Double {
                            print(String(format: "LOCALAIM iPhone: screen=(%.1f, %.1f) markers=%d/8 detected=%@ det=%.1fms",
                                         x, y, n, detected.map(String.init).joined(separator: ","), detMs))
                            self?.logLocalAim(markers: n, ids: detected, x: x, y: y,
                                              detectMs: detMs, src: "tcp")
                            let text = String(format: "iPhone 瞄准: (%.1f, %.1f)  标记 %d/8", x, y, n)
                            DispatchQueue.main.async { [weak self] in
                                self?.debugLabel?.stringValue = text
                                self?.debugLabel?.textColor = .white
                            }
                        } else {
                            let missStr = missing.map(String.init).joined(separator: ",")
                            // 冗余 8 标记下 <4 个匹配才无输出（ADR-007），比旧"缺角即无输出"宽松得多
                            print(String(format: "LOCALAIM iPhone: 检出不足（%d 个，缺 [%@]），无瞄准点 det=%.1fms",
                                         n, missStr, detMs))
                            self?.logLocalAim(markers: n, ids: detected, x: nil, y: nil,
                                              detectMs: detMs, src: "tcp")
                            DispatchQueue.main.async { [weak self] in
                                self?.debugLabel?.stringValue = "iPhone 瞄准: 缺定位码 [\(missStr)]（检出 \(n)/8）"
                                self?.debugLabel?.textColor = .systemYellow
                            }
                        }
                    default:
                        break
                    }
                }
                // 监听失败（典型：端口被旧实例占用）→ 弹窗说明并退出，
                // 绝不留着没有服务能力的二维码继续显示（僵尸二维码）
                server.onListenerFailed = { err in
                    let alert = NSAlert()
                    alert.messageText = "帧服务启动失败（端口 \(port)）"
                    alert.informativeText = "\(err.localizedDescription)\n\n通常是已有另一个 ScreenAim 实例正在运行。请先退出旧实例（或在其窗口按 ESC），再启动本实例。"
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "退出")
                    alert.runModal()
                    NSApp.terminate(nil)
                }
                try server.start()
                objc_setAssociatedObject(win, "server", server, .OBJC_ASSOCIATION_RETAIN)
            } catch {
                // 同步 throw（如非法端口）：同样不允许带病运行
                fputs("帧服务启动失败: \(error.localizedDescription)\n", stderr)
                let alert = NSAlert()
                alert.messageText = "帧服务启动失败（端口 \(port)）"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.addButton(withTitle: "退出")
                alert.runModal()
                NSApp.terminate(nil)
            }
        } else {
            // 本机屏幕采样模式
            Task {
                do { try await sampler.start() } catch {
                    fputs("错误: \(error.localizedDescription)\n", stderr)
                }
            }
        }
        print(String(format: "透明标定层已显示: 标记 %.0fpt (%.0f 物理像素) + %.0fpt 白卡，边距 %.0fpt，ESC 退出",
                     markerSize, markerSize * screen.backingScaleFactor, pad, inset))
        app.run()
        exit(0)
    }
}

// MARK: - 入口
if CommandLine.arguments.contains("--self-test") {
    // 离线自检：生成测试场景 -> 检测 8 个标记 -> RANSAC 单应映射帧中心（含遮挡模拟，ADR-007）
    let scenePath = "/tmp/screenaim_test_scene.png"
    do {
        try OpenCVBridge.generateTestScene(toFile: scenePath)
        let found = OpenCVBridge().detectMarkers(inImageFile: scenePath)
        guard found.count == 8 else {
            print("自检失败: 期望 8 个标记，检测到 \(found.count) 个")
            exit(1)
        }
        for m in found.sorted(by: { $0.markerId < $1.markerId }) {
            print(String(format: "  id=%d center=(%.1f, %.1f)",
                         m.markerId, m.center.x, m.center.y))
        }
        // 场景是 1000x800 画布（标记边长 100）：角标记中心 (100,100)(900,100)(900,700)(100,700)，
        // 边中点 (500,100)(900,400)(500,700)(100,400)；逻辑区域为角标记中心围成的 800x600 矩形
        let logical: [Int32: CGPoint] = [
            0: CGPoint(x: 0, y: 0), 1: CGPoint(x: 800, y: 0),
            2: CGPoint(x: 800, y: 600), 3: CGPoint(x: 0, y: 600),
            4: CGPoint(x: 400, y: 0), 5: CGPoint(x: 800, y: 300),
            6: CGPoint(x: 400, y: 600), 7: CGPoint(x: 0, y: 300),
        ]
        // 遮挡模拟：dropIDs 从检测集中剔除后仍应求解成功且误差 < 2pt
        func mappedError(drop dropIDs: Set<Int32>) -> Double? {
            var src: [NSValue] = [], dst: [NSValue] = []
            for m in found where !dropIDs.contains(Int32(m.markerId)) {
                guard let d = logical[Int32(m.markerId)] else { continue }
                src.append(NSValue(point: m.center))
                dst.append(NSValue(point: d))
            }
            var ok = ObjCBool(false)
            let mapped = OpenCVBridge.mapPointRANSAC(CGPoint(x: 500, y: 400),
                                                     srcPoints: src, dstPoints: dst,
                                                     success: &ok)
            guard ok.boolValue else { return nil }
            return hypot(mapped.x - 400, mapped.y - 300)
        }
        if let err = mappedError(drop: []) {
            print(String(format: "  全量 8 标记: 帧中心(500,400) -> 逻辑坐标，误差 %.2fpt（期望≈(400,300)）", err))
            guard err <= 2 else { print("自检失败: 映射误差 \(err)pt"); exit(1) }
        } else { print("自检失败: 全量标记单应求解失败"); exit(1) }
        // 逐一遮挡每个角标记：输出不得中断
        for corner: Int32 in [0, 1, 2, 3] {
            guard let err = mappedError(drop: [corner]) else {
                print("自检失败: 遮挡角标记 id=\(corner) 后无输出"); exit(1)
            }
            print(String(format: "  遮挡角 id=%d: 误差 %.2fpt", corner, err))
            guard err <= 2 else { print("自检失败: 遮挡 id=\(corner) 后误差 \(err)pt"); exit(1) }
        }
        // 遮挡两个相邻角（不相对）：误差 < 2pt
        if let err = mappedError(drop: [0, 1]) {
            print(String(format: "  遮挡相邻双角 id=0,1: 误差 %.2fpt", err))
            guard err <= 2 else { print("自检失败: 遮挡双角后误差 \(err)pt"); exit(1) }
        } else { print("自检失败: 遮挡相邻双角后无输出"); exit(1) }
        print("自检通过 ✅ (场景图: \(scenePath))")
        exit(0)
    } catch {
        fputs("自检错误: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--swift-self-test") {
    setbuf(stdout, nil)
    // 纯 Swift 检测器（iOS 端同款代码）离线自检：与 --self-test 相同的场景与判据
    let scenePath = "/tmp/screenaim_test_scene.png"
    do {
        try OpenCVBridge.generateTestScene(toFile: scenePath)
        guard let (data, w, h) = loadBGRA(from: scenePath) else {
            print("自检失败: 场景图加载失败"); exit(1)
        }
        let localizer = ScreenLocalizer()
        localizer.detector.debugLog = true
        // 场景 1000x800（标记边长 100）：角标记中心 (100,100)(900,100)(900,700)(100,700)，
        // 边中点 (500,100)(900,400)(500,700)(100,400)；逻辑矩形 800x600（角）+ 边中点
        localizer.screenCornerMap = [
            0: CGPoint(x: 0, y: 0), 1: CGPoint(x: 800, y: 0),
            2: CGPoint(x: 800, y: 600), 3: CGPoint(x: 0, y: 600),
            4: CGPoint(x: 400, y: 0), 5: CGPoint(x: 800, y: 300),
            6: CGPoint(x: 400, y: 600), 7: CGPoint(x: 0, y: 300),
        ]
        let result = data.withUnsafeBytes { ptr in
            localizer.localize(bgra: ptr.baseAddress!, width: w, height: h, bytesPerRow: w * 4)
        }
        guard result.markers.count == 8 else {
            print("自检失败: 期望 8 个标记，Swift 检测器检出 \(result.markers.count) 个")
            for m in result.markers { print("  检出 id=\(m.id) center=(\(m.center.x), \(m.center.y))") }
            exit(1)
        }
        let truth: [Int: CGPoint] = [
            0: CGPoint(x: 100, y: 100), 1: CGPoint(x: 900, y: 100),
            2: CGPoint(x: 900, y: 700), 3: CGPoint(x: 100, y: 700),
            4: CGPoint(x: 500, y: 100), 5: CGPoint(x: 900, y: 400),
            6: CGPoint(x: 500, y: 700), 7: CGPoint(x: 100, y: 400),
        ]
        for m in result.markers {
            let t = truth[m.id]!
            let err = hypot(m.center.x - t.x, m.center.y - t.y)
            print(String(format: "  id=%d center=(%.1f, %.1f) 真值=(%.0f, %.0f) 误差=%.2fpx",
                         m.id, m.center.x, m.center.y, t.x, t.y, err))
            if err > 2 { print("自检失败: id=\(m.id) 中心误差 \(err)px"); exit(1) }
        }
        guard let aim = result.aim else { print("自检失败: 单应求解失败"); exit(1) }
        print(String(format: "  帧中心(500,400) -> 逻辑坐标 (%.1f, %.1f)，期望约 (400, 300)",
                     aim.x, aim.y))
        let err = hypot(aim.x - 400, aim.y - 300)
        if err > 2 { print("自检失败: 映射误差 \(err)pt"); exit(1) }
        // 遮挡模拟（纯 Swift RANSAC 路径）：用检出中心子集直接求解，判据同 --self-test
        func swiftMappedError(drop dropIDs: Set<Int>) -> Double? {
            var src: [CGPoint] = [], dst: [CGPoint] = []
            for m in result.markers where !dropIDs.contains(m.id) {
                guard let d = localizer.screenCornerMap[m.id] else { continue }
                src.append(m.center); dst.append(d)
            }
            guard let h = Homography(ransacSrc: src, dst: dst) else { return nil }
            let p = h.map(CGPoint(x: 500, y: 400))
            return hypot(p.x - 400, p.y - 300)
        }
        for corner in [0, 1, 2, 3] {
            guard let e = swiftMappedError(drop: [corner]), e <= 2 else {
                print("自检失败: 遮挡角 id=\(corner) 后无输出或误差超标"); exit(1)
            }
            print(String(format: "  遮挡角 id=%d: 误差 %.2fpt", corner, e))
        }
        guard let e = swiftMappedError(drop: [0, 1]), e <= 2 else {
            print("自检失败: 遮挡相邻双角后无输出或误差超标"); exit(1)
        }
        print(String(format: "  遮挡相邻双角 id=0,1: 误差 %.2fpt", e))
        print("Swift 检测器自检通过 ✅")
        exit(0)
    } catch {
        fputs("自检错误: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if let di = CommandLine.arguments.firstIndex(of: "--swift-detect"),
   CommandLine.arguments.count > di + 1 {
    // 双检测器对比：OpenCV（参照） vs 纯 Swift（iOS 同款）
    // 可选第三个参数为 ground-truth JSON: {"markers":{"0":[x,y],...},"logical":{"0":[x,y],...}}
    let imgPath = CommandLine.arguments[di + 1]
    guard let (data, w, h) = loadBGRA(from: imgPath) else {
        fputs("图像加载失败: \(imgPath)\n", stderr); exit(1)
    }
    let bridge = OpenCVBridge()
    let cvMarkers = data.withUnsafeBytes { ptr in
        bridge.detectMarkers(inBGRABuffer: ptr.baseAddress!, width: Int32(w), height: Int32(h))
    }
    let localizer = ScreenLocalizer()
    localizer.detector.debugLog = CommandLine.arguments.contains("--verbose")
    let t0 = CACurrentMediaTime()
    let swResult = data.withUnsafeBytes { ptr in
        localizer.localize(bgra: ptr.baseAddress!, width: w, height: h, bytesPerRow: w * 4)
    }
    let elapsedMs = (CACurrentMediaTime() - t0) * 1000
    // verbose 时导出二值图，肉眼检查阈值分割质量
    if localizer.detector.debugLog, !localizer.detector.lastDark.isEmpty {
        var px = localizer.detector.lastDark.map { $0 * 255 }
        let dw = localizer.detector.lastSize.w, dh = localizer.detector.lastSize.h
        if let ctx = CGContext(data: &px, width: dw, height: dh,
                               bitsPerComponent: 8, bytesPerRow: dw,
                               space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGImageAlphaInfo.none.rawValue),
           let cg = ctx.makeImage() {
            let dst = URL(fileURLWithPath: "/tmp/swift_thresh.png")
            if let dest = CGImageDestinationCreateWithURL(dst as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, nil)
                CGImageDestinationFinalize(dest)
                print("二值图已导出: /tmp/swift_thresh.png")
            }
        }
    }

    print("== OpenCV 检出 \(cvMarkers.count) 个 ==")
    for m in cvMarkers.sorted(by: { $0.markerId < $1.markerId }) {
        print(String(format: "  id=%d center=(%.1f, %.1f)", m.markerId, m.center.x, m.center.y))
    }
    print(String(format: "== Swift 检出 %d 个（%.1f ms）==", swResult.markers.count, elapsedMs))
    for m in swResult.markers {
        print(String(format: "  id=%d center=(%.1f, %.1f)", m.id, m.center.x, m.center.y))
    }
    // 同 id 中心距
    for sm in swResult.markers {
        if let cm = cvMarkers.first(where: { $0.markerId == sm.id }) {
            print(String(format: "  id=%d 中心距 %.2fpx", sm.id,
                         hypot(sm.center.x - cm.center.x, sm.center.y - cm.center.y)))
        }
    }
    // 映射对比：dst 用真值 logical（若提供），否则用图像矩形四角
    var logical: [Int: CGPoint] = [
        0: CGPoint(x: 0, y: 0), 1: CGPoint(x: w, y: 0),
        2: CGPoint(x: w, y: h), 3: CGPoint(x: 0, y: h),
    ]
    var gtMarkers: [Int: CGPoint]? = nil
    var gtAim: CGPoint? = nil
    if CommandLine.arguments.count > di + 2,
       let gtData = FileManager.default.contents(atPath: CommandLine.arguments[di + 2]),
       let gt = try? JSONSerialization.jsonObject(with: gtData) as? [String: Any] {
        if let lg = gt["logical"] as? [String: [Double]] {
            logical = lg.reduce(into: [:]) { $0[Int($1.key) ?? -1] = CGPoint(x: $1.value[0], y: $1.value[1]) }
        }
        if let gm = gt["markers"] as? [String: [Double]] {
            gtMarkers = gm.reduce(into: [:]) { $0[Int($1.key) ?? -1] = CGPoint(x: $1.value[0], y: $1.value[1]) }
        }
        if let at = gt["aimTruth"] as? [Double] { gtAim = CGPoint(x: at[0], y: at[1]) }
    }
    // 有真值时直接对真值评估 Swift 检测器
    func aimWith(_ centers: [Int: CGPoint]) -> CGPoint? {
        var src: [CGPoint] = [], dst: [CGPoint] = []
        for id in 0..<4 {
            guard let s = centers[id], let d = logical[id] else { return nil }
            src.append(s); dst.append(d)
        }
        return Homography(src: src, dst: dst)?.map(CGPoint(x: w / 2, y: h / 2))
    }
    let cvCenters = cvMarkers.reduce(into: [Int: CGPoint]()) { $0[Int($1.markerId)] = $1.center }
    let swCenters = swResult.markers.reduce(into: [Int: CGPoint]()) { $0[$1.id] = $1.center }
    if let gtMarkers, let gtAim {
        var maxErr = 0.0
        for m in swResult.markers {
            if let t = gtMarkers[m.id] {
                maxErr = max(maxErr, hypot(m.center.x - t.x, m.center.y - t.y))
            }
        }
        if let b = aimWith(swCenters) {
            print(String(format: "Swift 对真值: 中心最大误差 %.2fpx, 瞄准点 (%.1f, %.1f) vs 真值 (%.1f, %.1f) 差 %.2f",
                         maxErr, b.x, b.y, gtAim.x, gtAim.y, hypot(b.x - gtAim.x, b.y - gtAim.y)))
        } else {
            print("Swift 对真值: 未集齐 4 角（检出 \(swResult.markers.count)）")
        }
    }
    if let a = aimWith(cvCenters), let b = aimWith(swCenters) {
        print(String(format: "瞄准点: OpenCV (%.1f, %.1f) vs Swift (%.1f, %.1f)，差 %.2f",
                     a.x, a.y, b.x, b.y, hypot(a.x - b.x, a.y - b.y)))
    } else {
        print("瞄准点: 至少一个检测器未集齐 4 角，无法对比")
    }
    exit(0)
}

if CommandLine.arguments.contains("--make-markers") {
    let dir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "./markers"
    do {
        // 8 个：id0–3 四角 + id4–7 四边中点（ADR-007）
        try OpenCVBridge.generateMarkers(toDirectory: dir, count: 8, sidePixels: 400)
        print("已生成 8 个校准标记到 \(dir)")
    } catch {
        fputs("错误: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    exit(0)
}

if CommandLine.arguments.contains("--calibrate") {
    setbuf(stdout, nil)
    // 标记边长（点），默认 24pt（Retina 48 物理像素）——实测可靠下限
    // 更大更稳：手机距离远或光线差时可调大，如 --marker-size 48
    var size: CGFloat = 24
    if let i = CommandLine.arguments.firstIndex(of: "--marker-size"),
       CommandLine.arguments.count > i + 1,
       let v = Double(CommandLine.arguments[i + 1]), v >= 16 {
        size = CGFloat(v)
    }
    var inset: CGFloat = 24
    if let i = CommandLine.arguments.firstIndex(of: "--inset"),
       CommandLine.arguments.count > i + 1,
       let v = Double(CommandLine.arguments[i + 1]), v >= 0 {
        inset = CGFloat(v)
    }
    var pad: CGFloat = 8
    if let i = CommandLine.arguments.firstIndex(of: "--pad"),
       CommandLine.arguments.count > i + 1,
       let v = Double(CommandLine.arguments[i + 1]), v >= 0 {
        pad = CGFloat(v)
    }
    // --serve PORT: 手机推流模式，TCP 收 JPEG 帧而不采本机屏幕
    var servePort: UInt16? = nil
    if let i = CommandLine.arguments.firstIndex(of: "--serve"),
       CommandLine.arguments.count > i + 1,
       let v = UInt16(CommandLine.arguments[i + 1]) {
        servePort = v
    }
    // 顶层全局强引用持有 Calibrator，保证滑杆/按钮闭包里的 weak self 在整个生命周期有效
    let calibrator = Calibrator(markerSize: size, inset: inset, pad: pad, servePort: servePort)
    calibrator.run()  // 阻塞
}

let sampler = ScreenSampler()
setbuf(stdout, nil)  // 管道输出时禁用缓冲，日志实时可见
// 示例：四角标记对应的屏幕逻辑坐标（换成你标定窗口的实际布局）
sampler.screenCornerMap = [
    0: CGPoint(x: 0, y: 0),
    1: CGPoint(x: 1280, y: 0),
    2: CGPoint(x: 1280, y: 800),
    3: CGPoint(x: 0, y: 800),
]

Task {
    do {
        try await sampler.start()
    } catch {
        fputs("错误: \(error.localizedDescription)\n", stderr)
        fputs("提示: 首次运行需在 系统设置 > 隐私与安全性 > 屏幕录制 中授权终端/Xcode\n", stderr)
        exit(1)
    }
}

// MARK: - 鼠标模拟器事件注入（protocol.md §8，横屏触控层 → 本机光标）
/// 在当前光标位置点击一次。button: "left" / "right" / "middle"
/// 需 系统设置 > 隐私与安全性 > 辅助功能 授权，否则事件被系统静默丢弃
func postMouseClick(_ button: String) {
    guard let pos = CGEvent(source: nil)?.location else { return }
    let (downType, upType, cgButton): (CGEventType, CGEventType, CGMouseButton)
    switch button {
    case "right":  (downType, upType, cgButton) = (.rightMouseDown, .rightMouseUp, .right)
    case "middle": (downType, upType, cgButton) = (.otherMouseDown, .otherMouseUp, .center)
    default:       (downType, upType, cgButton) = (.leftMouseDown, .leftMouseUp, .left)
    }
    CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: pos, mouseButton: cgButton)?
        .post(tap: .cghidEventTap)
    CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: pos, mouseButton: cgButton)?
        .post(tap: .cghidEventTap)
}

/// 滚轮滚动。delta 为刻度（行）数，正 = 向上滚（与手机端手指上滑同向）
func postMouseScroll(_ delta: Int) {
    CGEvent(scrollWheelEvent2Source: nil, units: .line,
            wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0)?
        .post(tap: .cghidEventTap)
}

RunLoop.main.run()
