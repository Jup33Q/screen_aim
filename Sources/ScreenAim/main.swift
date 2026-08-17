//
//  main.swift
//  ScreenAim（Mac 端）— 采集/接收帧 → ArUco 检测 → 单应映射 → 瞄准坐标输出；
//  手机推流模式（--serve）含鼠标模拟：控制信道 → CGEvent 注入（protocol.md §8）
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
/// 两条入口：`start()` 起 SCStream 本机采屏；`processJPEG(_:)` 由 FrameServerV2 喂手机帧。
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
    // 输出侧 One Euro 滤波（Phase 1.3，与 ScreenLocalizer 同款参数）：x/y 各一实例
    private var aimFilterX = OneEuroFilter(), aimFilterY = OneEuroFilter()
    private var noAimFrames = 0

    // 屏幕定位码 ID -> 屏幕坐标（左上角原点，单位：点）；≥4 项即可映射（冗余 8 标记，ADR-007）
    // dst 用什么单位，映射结果就是什么单位；homography 自动吸收采样降分辨率的比例
    var screenCornerMap: [Int32: CGPoint] = [:]

    // 检测到有效映射时回调（左上角原点，点坐标）
    var onAim: ((CGPoint) -> Void)?

    /// 每帧检出标记 ID 回调（帧处理队列上调用，两种入口都会触发）：
    /// 标定层定位码"激活"绿边的数据源
    var onMarkersDetected: (([Int]) -> Void)?

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
        onMarkersDetected?(markers.map { Int($0.markerId) })

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
        guard src.count >= 4 else {
            registerNoAim()
            return
        }

        var ok = ObjCBool(false)
        // 帧中心 = 瞄准点；结果单位与 screenCornerMap 一致（点坐标，左上角原点）
        let mapped = OpenCVBridge.mapPointRANSAC(CGPoint(x: w / 2, y: h / 2),
                                                 srcPoints: src, dstPoints: dst,
                                                 success: &ok)
        guard ok.boolValue else {
            registerNoAim()
            return
        }
        noAimFrames = 0
        // One Euro 滤波（Phase 1.3）：墙钟 dt（本队列逐帧处理，间隔即帧间隔）
        let t = CACurrentMediaTime()
        let filtered = CGPoint(x: aimFilterX.filter(mapped.x, at: t),
                               y: aimFilterY.filter(mapped.y, at: t))
        print(String(format: "瞄准点 -> 屏幕坐标 (%.0f, %.0f)", filtered.x, filtered.y))
        onAim?(filtered)
    }

    /// 连续 10 帧无输出后重置滤波器：避免恢复后瞄准点被过期状态拖走（与 ScreenLocalizer 同策略）
    private func registerNoAim() {
        noAimFrames += 1
        if noAimFrames >= 10 {
            aimFilterX.reset()
            aimFilterY.reset()
            noAimFrames = 0
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
/// 进度弧随值填充）+ 上层数值文本。量程/后缀可配（pt 尺寸与 % 不透明度共用）
final class SizeBadgeView: NSView {
    var value: Int = 16 { didSet { update() } }
    var minV = 16.0, maxV = 96.0
    var suffix = ""
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
                                 accessibilityDescription: "定位码参数")
        label.stringValue = "\(value)\(suffix)"
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


// MARK: - 透明悬浮标定层
/// 全屏透明、点击穿透的悬浮窗口：四角 + 四边中点共 8 个悬浮 ArUco 标记（ADR-007）
/// +（推流模式）中央配对二维码。
///
/// - 每个标记自带白色圆角底卡，保证任意桌面背景下的 ArUco 静区（WARNING: 无静区无法检测）
/// - 标记中心坐标自动写入 `ScreenSampler.screenCornerMap`，无需手工标定
/// - 配对二维码内容 `{"host":ip,"port":port}`（port 即 TLV 端口，P3 收敛后），IP 每 5 秒轮询、变化即重生成
/// - `run()` 阻塞进 NSApp 主循环，ESC 退出
final class Calibrator: NSObject {
    var markerSize: CGFloat   // 标记边长（点），滑杆实时调整
    /// 标记卡不透明度（0.4–1.0，顶部面板滑杆实时调整）：
    /// 降低可减少视觉侵入；WARNING: 太低会压缩黑白对比度，识别率先受影响
    var markerAlpha: CGFloat = 0.75
    let inset: CGFloat        // 标记中心距屏幕边缘的距离（点）
    let pad: CGFloat          // 白卡内边距（点），保证静区
    let servePort: UInt16?    // 非 nil：手机推流模式（不采本机屏幕）
    /// --aim-cursor：识别输出的瞄准点直接绑定鼠标光标位置（CGWarpMouseCursorPosition）
    let aimCursor: Bool
    var window: NSWindow?
    var qrCard: NSView?       // 配对二维码卡片（连接成功后隐藏）
    var qrHost: NSView?       // 二维码视觉容器（玻璃模块层 / 位图回退都加在这里）
    /// 立即按当前 IP 重新生成配对二维码（IP 看守计时器与手机断开通知共用）
    var refreshQRNow: (() -> Void)?
    var qrButton: ActionButton?  // Mac 端配对码开关按钮（悬浮 NSPanel 上）
    /// 数据采集状态（protocol.md §10）：录制中按钮变红，采集上传收完自动复位
    var capturing = false
    var captureButton: ActionButton?
    var captureLabel = ""
    var currentPayload = ""
    var debugLabel: NSTextField?  // 手机端本机识别结果（localAim）的悬浮 debug 文本
    /// iPhone 数据流瞄准点白点覆盖层：位置完全来自 protocol.md §7 localAim 上报
    /// （手机本机识别结果），与 Mac 端视频帧识别管线无关；滑行预算耗尽/断连时隐藏
    var aimDot: NSView?
    /// Mac 显示段滤波（WP3.3 分层解耦，ADR-014）：iPhone 识别段已强消抖，本段只做
    /// ≈15Hz 上报（ADR-009）→ 显示的插值平滑 + 跳变门 + 断流滑行，不重复消抖
    /// （双段都强消抖时横扫滞后叠加）。断流帧白点按速度衰减外推滑行（WP3.2，
    /// 与 iPhone 段共用 AimCoastFilter），最多 maxCoastFrames 帧才隐藏。
    /// 参数由 --filter-preset / 四个单项旋钮注入（口语化指南 docs/aim-filter-tuning.md）；
    /// 断连即重置，恢复后从最新瞄准点重新开始，不被过期状态拖走；
    /// 滑行耗尽后连续 10 帧无瞄准点才重置（与 ScreenSampler.registerNoAim 同策略）。
    /// 60Hz 显示定时器另用其只读接口 displayExtrapolation 在两次上报空窗内
    /// 匀速死推算重摆白点（WP-L1，ADR-015），不改滤波状态、不计入滑行预算
    let dotFilter = AimCoastFilter(params: AimFilterPreset.daily.macDisplay)
    /// 当前生效的口语化预设（calib 负载 filterPreset 字段下发给 iPhone 识别段，WP3.4）
    var filterPreset: AimFilterPreset = .daily
    /// 连续无瞄准点的 localAim 帧计数（主线程访问）：≥10 才重置 dotFilter
    private var dotNoAimFrames = 0

    /// 白点摆点共用换算（WP-L1 抽出，ADR-015）：屏幕点坐标（左上角原点）→
    /// AppKit 左下角原点（y 翻转 + 屏内钳制），摆 aimDot 并置可见。
    /// localAim 到达帧 / 断流滑行帧 / 60Hz 外推定时器三处共用——禁止复制第二份，
    /// 两份换算漂移会让外推点与权威位置打架
    private func placeAimDot(at p: CGPoint) {
        guard let dot = aimDot, screenW > 0 else { return }
        let d = dot.frame.width
        let cx = min(max(p.x, 0), screenW - 1)
        let cy = min(max(p.y, 0), screenH - 1)
        dot.frame = NSRect(x: cx - d / 2, y: screenH - cy - d / 2,
                           width: d, height: d)
        dot.isHidden = false
    }
    var centers: [CGPoint] = []        // 当前 8 个标记中心的屏幕点坐标（左上角原点）
    var markerCards: [NSView] = []     // 当前 8 块白卡视图（rebuildMarkers 重建）
    /// 当前被识别到（激活）的标记 ID 集合：setMarkerActivation 增量比对，仅翻转项发动画
    private var activeMarkerIDs: Set<Int> = []
    var screenW: CGFloat = 0           // 屏幕点尺寸（calib 负载用）
    var screenH: CGFloat = 0

    // localAim 结构化日志：每条上报追加一行 CSV（时间戳/检出数/坐标），供离线分析手机端识别质量
    private let csvLock = NSLock()
    private var csvHandle: FileHandle?
    private let csvStamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")

    // 鼠标模拟器（protocol.md §8）：Mac 侧跟踪按下中的键，断开连接时补发 up 防止键卡死（ADR-008）；
    // mouseCsvHandle 为信号捕获日志（scenes/mouse_<会话时间>.csv），首次写时创建
    private var pressedMouseButtons: Set<String> = []
    private var mouseCsvHandle: FileHandle?
    private var mousePermWarned = false   // 辅助功能未授权的一次性警告去重

    /// 追加一条 localAim 记录到 scenes/localaim_<会话时间>.csv（onControl 在 conn 队列，加锁串行化）。
    /// 列：timestamp,markers,ids,x,y,detect_ms,src,quality。ids 为本帧检出的标记 ID（如 "0|2"），
    /// 缺失的标记 = 全集减去该集合；detect_ms 为上报端检测耗时（旧客户端无此字段时为 0）；
    /// src 为数据来源通道（目前恒为 tlv；旧链路历史数据为 tcp），离线分析用；
    /// quality 为输出等级（WP1 新增列，只加不删：homography/affine/coast；旧客户端无此字段时留空）
    func logLocalAim(markers n: Int, ids: [Int], x: Double?, y: Double?,
                     detectMs: Double, src: String, quality: String? = nil) {
        csvLock.lock(); defer { csvLock.unlock() }
        if csvHandle == nil {
            let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("scenes", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("localaim_\(csvStamp).csv")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path,
                                               contents: "timestamp,markers,ids,x,y,detect_ms,src,quality\n".data(using: .utf8))
            }
            csvHandle = FileHandle(forWritingAtPath: url.path)
            csvHandle?.seekToEndOfFile()
            if csvHandle != nil { print("localAim 日志: \(url.path)") }
        }
        let xy: String = (x != nil && y != nil) ? String(format: "%.1f,%.1f", x!, y!) : ","
        let idStr = ids.map(String.init).joined(separator: "|")
        let row = String(format: "%.3f,%d,%@,%@,%.1f,%@,%@\n",
                         Date().timeIntervalSince1970, n, idStr, xy, detectMs, src, quality ?? "")
        if let data = row.data(using: .utf8) { csvHandle?.write(data) }
    }

    /// 鼠标模拟器信号捕获日志（protocol.md §8）：每条事件追加一行到
    /// scenes/mouse_<会话时间>.csv。列：timestamp,event,button,delta
    /// （event ∈ down/up/click/scroll；scroll 时 button 为空、delta 为刻度增量）。
    /// onControl 在 conn 队列，与 logLocalAim 共用 csvLock 串行化
    func logMouseEvent(event: String, button: String, delta: Int) {
        csvLock.lock(); defer { csvLock.unlock() }
        if mouseCsvHandle == nil {
            let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("scenes", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("mouse_\(csvStamp).csv")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path,
                                               contents: "timestamp,event,button,delta\n".data(using: .utf8))
            }
            mouseCsvHandle = FileHandle(forWritingAtPath: url.path)
            mouseCsvHandle?.seekToEndOfFile()
            if mouseCsvHandle != nil { print("鼠标信号日志: \(url.path)") }
        }
        let row = String(format: "%.3f,%@,%@,%d\n",
                         Date().timeIntervalSince1970, event, button, delta)
        if let data = row.data(using: .utf8) { mouseCsvHandle?.write(data) }
    }

    /// 辅助功能未授权的一次性警告（CGEvent 会被系统静默丢弃，不提示则排障无迹可寻）
    private func warnIfMousePermissionMissing() {
        guard !AXIsProcessTrusted(), !mousePermWarned else { return }
        mousePermWarned = true
        print("警告: 未授权辅助功能，鼠标点击/滚动将被系统静默丢弃"
              + "（系统设置 > 隐私与安全性 > 辅助功能）")
    }

    /// 鼠标按下/抬起分发（onControl 在 conn 队列）：注入 CGEvent、维护按下键集合、
    /// 写捕获日志、刷新 debug 标签。button == "all" 仅用于 up：对全部按下键补发抬起
    /// （iPhone 断开连接前的兜底帧，protocol.md §8）。返回 false 表示消息字段非法
    @discardableResult
    func handleMouseButton(event: String, button: String) -> Bool {
        guard ["left", "right", "middle"].contains(button)
              || (event == "up" && button == "all") else { return false }
        warnIfMousePermissionMissing()
        if event == "down" {
            postMouseDown(button)
            csvLock.lock(); pressedMouseButtons.insert(button); csvLock.unlock()
        } else {
            if button == "all" {
                csvLock.lock()
                let stuck = pressedMouseButtons
                pressedMouseButtons.removeAll()
                csvLock.unlock()
                for b in stuck { postMouseUp(b) }
            } else {
                postMouseUp(button)
                csvLock.lock(); pressedMouseButtons.remove(button); csvLock.unlock()
            }
        }
        logMouseEvent(event: event, button: button, delta: 0)
        print("MOUSE \(event): \(button)")
        DispatchQueue.main.async { [weak self] in
            self?.debugLabel?.stringValue = "鼠标: \(button) \(event == "down" ? "按下" : "抬起")"
            self?.debugLabel?.textColor = .white
        }
        return true
    }

    /// 连接断开兜底：对仍处按下状态的键补发 up，防止真实鼠标键卡死
    /// （FrameServerV2.onDisconnect / 收到 disconnect 消息时调用）
    func releaseStuckMouseButtons() {
        csvLock.lock()
        let stuck = pressedMouseButtons
        pressedMouseButtons.removeAll()
        csvLock.unlock()
        for b in stuck {
            postMouseUp(b)
            logMouseEvent(event: "up", button: b, delta: 0)
            print("MOUSE up: \(b)（连接断开兜底）")
        }
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
            // WARNING: 上中标记要躲物理刘海——safeAreaInsets.top 以下才是完整显示区，
            // 贴顶放会被刘海盖住上半截（外接屏 safeTop=0，退化为与其他边一致）
            CGPoint(x: W / 2, y: screen.safeAreaInsets.top + m + s / 2),  // 4 上中
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
            // 激活描边：初始透明，被识别到时由 setMarkerActivation 描绿边
            cardView.layer?.borderWidth = 2.5
            cardView.layer?.borderColor = NSColor.clear.cgColor
            // 半透化降低视觉侵入（真机用户反馈全白卡太刺眼）；
            // 0.75 下白环对深色桌面仍 ~190 灰度，解码对比度余量充足
            cardView.layer?.opacity = Float(markerAlpha)
            content.addSubview(cardView)
            let iv = NSImageView(frame: NSRect(x: pad, y: pad, width: s, height: s))
            iv.image = images[id]
            iv.imageScaling = .scaleAxesIndependently
            cardView.addSubview(iv)
            markerCards.append(cardView)
        }
        // 重建（滑杆调尺寸）后恢复激活态：当前激活中的标记直接描绿边，不走动画
        for i in activeMarkerIDs where i < markerCards.count {
            markerCards[i].layer?.borderColor = NSColor.systemGreen.cgColor
        }
        centers = newCenters
        return centers
    }

    /// 定位码激活边框（主线程调用）：被识别到的标记白卡描绿边（标的被激活），
    /// 掉检的恢复透明；激活/失效的颜色变化走 10ms 渐变动画而非瞬时跳变。
    /// 增量比对 activeMarkerIDs，仅状态翻转的卡发动画，避免每帧全量刷动画
    func setMarkerActivation(_ ids: Set<Int>) {
        guard ids != activeMarkerIDs else { return }
        let green = NSColor.systemGreen.cgColor
        let clear = NSColor.clear.cgColor
        for (i, card) in markerCards.enumerated() {
            let active = ids.contains(i)
            guard active != activeMarkerIDs.contains(i), let layer = card.layer else { continue }
            let target = active ? green : clear
            let anim = CABasicAnimation(keyPath: "borderColor")
            anim.fromValue = layer.presentation()?.borderColor ?? layer.borderColor
            anim.toValue = target
            anim.duration = 0.01   // 10ms 渐变（激活与失效同值）
            layer.borderColor = target
            layer.add(anim, forKey: "activationBorder")
        }
        activeMarkerIDs = ids
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
            // 口语化滤波预设（WP3.4，protocol.md §6：只加不删，旧版 iPhone 忽略该字段、
            // 保持其编译期默认档）
            "filterPreset": filterPreset.rawValue,
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    init(markerSize: CGFloat, inset: CGFloat, pad: CGFloat = 8, servePort: UInt16? = nil,
         aimCursor: Bool = false) {
        self.markerSize = markerSize
        self.inset = inset
        self.pad = pad
        self.servePort = servePort
        self.aimCursor = aimCursor
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
        // 鼠标模拟器（protocol.md §8）只在手机推流模式（--serve）存在；
        // 该模式下提前触发辅助功能授权弹窗，否则 CGEvent 注入会被系统静默丢弃
        if servePort != nil {
            if !AXIsProcessTrusted() {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
                print("提示: 手机鼠标模拟需授权辅助功能"
                      + "（系统设置 > 隐私与安全性 > 辅助功能），未授权时点击/滚动无效")
            }
        } else {
            print("提示: 未启用 --serve，手机无法连接；手机鼠标模拟需 --calibrate --serve PORT")
        }
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
            // port 即 TLV 服务端口（P3 收敛后单端口单服务，protocol.md §11）
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
        // 定位码激活联动：每帧检出的标记 ID 集合 -> 白卡绿边（主线程更新，内部去重 + 渐变动画）
        sampler.onMarkersDetected = { [weak self] ids in
            DispatchQueue.main.async { self?.setMarkerActivation(Set(ids)) }
        }
        if let port = servePort {
            // 手机推流模式：TCP 收 JPEG 帧 -> 检测
            do {
                // DEBUG: 手机端本机识别结果悬浮标签（点击穿透跟随主覆盖层）。
                // WARNING: 不能贴屏幕底边中央——下中标记 id6 的白卡占距底 16–56pt，
                // 胶囊抬高到 88pt 躲开（ADR-007 边中点布局引入的遮挡冲突）
                let dbgW: CGFloat = 380, dbgH: CGFloat = 30
                let dbgBg = NSView(frame: NSRect(x: W / 2 - dbgW / 2, y: 88,
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

                // iPhone 数据流瞄准点白点（protocol.md §7 localAim）：白底细黑边，
                // 深浅桌面都可见；初始隐藏，收到首个有效瞄准点才显示
                let dotD: CGFloat = 14
                let dot = NSView(frame: NSRect(x: 0, y: 0, width: dotD, height: dotD))
                dot.wantsLayer = true
                dot.layer?.backgroundColor = NSColor.white.cgColor
                dot.layer?.cornerRadius = dotD / 2
                dot.layer?.borderWidth = 1.5
                dot.layer?.borderColor = NSColor.black.withAlphaComponent(0.6).cgColor
                dot.isHidden = true
                win.contentView?.addSubview(dot)
                aimDot = dot

                // 60Hz 显示外推定时器（WP-L1，ADR-015）：两次 localAim 到达（≈15Hz）之间
                // 把白点重摆到 dotFilter 的匀速死推算外推点，填平显示空窗——"到达才摆"的
                // ≤66ms 保持滞后与阶梯感来源（白点滞后方案 §0 #6）。只动显示：权威位置
                // 仍是到达帧 update() 输出，断流滑行预算仍只由 update(raw: nil) 帧计数
                // 控制；白点隐藏时（滑行耗尽/断连/未初始化）空转直接返回。
                // 主 runloop 定时器与到达更新同在主线程（Calibrator 约定），无竞争
                Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                    guard let self, let dot = self.aimDot, !dot.isHidden else { return }
                    if let p = self.dotFilter.displayExtrapolation(at: CACurrentMediaTime()) {
                        self.placeAimDot(at: p)
                    }
                }

                // 帧处理解耦（识别慢于 15fps 到达率时丢旧帧保最新）：
                // 此前 onFrame 在 conn 队列同步执行，识别一帧期间不收下一帧，
                // TCP 缓冲积压 → 延迟累积、有效帧率远低于手机端。改为 busy 标志 +
                // 独立队列：处理中时新到的视频帧直接丢弃（视频帧可丢；控制帧在
                // 服务内联分发，不受此影响）
                let frameBusy = NSLock()
                var frameInFlight = false
                let frameQueue = DispatchQueue(label: "screenaim.frames")
                let processFrame: (Data) -> Void = { [sampler] jpeg in
                    frameBusy.lock()
                    if frameInFlight { frameBusy.unlock(); return }
                    frameInFlight = true
                    frameBusy.unlock()
                    frameQueue.async {
                        sampler.processJPEG(jpeg)
                        frameBusy.lock(); frameInFlight = false; frameBusy.unlock()
                    }
                }
                // TLV 单连接服务（protocol.md §11；P3 收敛后唯一传输服务，9100/_aimphone._tcp）
                let server = FrameServerV2(port: port, onFrame: processFrame)
                // 瞄准点绑定光标（--aim-cursor）：手机帧识别出的屏幕点直接 warp 鼠标，
                // 与 §8 触控点击配合 = 手机瞄哪里点哪里。瞄准点是主屏点坐标（左上角原点），
                // 与 Quartz 全局坐标系一致，直接传入；钳制在屏内防止单应外推甩飞光标
                if aimCursor {
                    sampler.onAim = { [weak self] pt in
                        guard let self else { return }
                        let clamped = CGPoint(x: min(max(pt.x, 0), self.screenW - 1),
                                              y: min(max(pt.y, 0), self.screenH - 1))
                        CGWarpMouseCursorPosition(clamped)
                    }
                    print("瞄准点已绑定鼠标光标（--aim-cursor），手机瞄哪里光标跟哪里")
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
                // 连接断开（主动/被动统一，§8）：按住中的鼠标键补发 up，防键卡死
                server.onDisconnect = { [weak self] in
                    self?.releaseStuckMouseButtons()
                    self?.setMarkerActivation([])   // 帧流中断，绿边全部失效
                }

                // Mac 端配对码开关 + 退出应用按钮 + 采集按钮 + 定位码大小/不透明度滑杆 + 隐藏 UI 按钮：
                // 主覆盖层点击穿透，所以单独用一个可点击的悬浮 NSPanel（屏幕顶部居中）
                let qrBtnW: CGFloat = 52, closeBtnW: CGFloat = 52, recBtnW: CGFloat = 52, btnGap: CGFloat = 8
                let sliderW: CGFloat = 210   // 滑杆胶囊（滑杆 + 数值标签）
                let alphaW: CGFloat = 170    // 不透明度滑杆胶囊（同布局，略窄）
                let eyeBtnW: CGFloat = 52    // 隐藏 UI 按钮胶囊
                let panelH: CGFloat = 44
                let panelW = qrBtnW + closeBtnW + recBtnW + btnGap * 5 + sliderW + alphaW + eyeBtnW
                // 面板上沿动态贴在上中标记 id4 白卡下沿 + 8pt：
                // 白卡占距顶 (safeTop+inset-pad) ~ (safeTop+inset+markerSize+pad)，
                // 固定偏移在标记调大后必然遮挡（真机 70pt 实测复现），尺寸滑杆回调里同步 reposition
                let safeTop = screen.safeAreaInsets.top
                let panelTopFromTop = { [weak self] () -> CGFloat in
                    safeTop + (self?.inset ?? 24) + (self?.markerSize ?? 48) + (self?.pad ?? 8) + 8
                }
                let btnPanel = NSPanel(contentRect: NSRect(x: W / 2 - panelW / 2,
                                                           y: H - panelTopFromTop() - panelH,
                                                           width: panelW, height: panelH),
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
                btnPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
                btnPanel.isOpaque = false
                btnPanel.backgroundColor = .clear
                btnPanel.hasShadow = false
                btnPanel.collectionBehavior = [.canJoinAllSpaces, .stationary]
                // 所有胶囊底卡登记在 capsules，隐藏 UI 时统一隐去（恢复胶囊单独管理）
                var capsules: [NSView] = []
                // 每个按钮各一块胶囊底卡
                func makeBtnBg(x: CGFloat, w: CGFloat) -> NSView {
                    let bg = NSView(frame: NSRect(x: x, y: 0, width: w, height: panelH))
                    bg.wantsLayer = true
                    bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
                    bg.layer?.cornerRadius = panelH / 2
                    btnPanel.contentView?.addSubview(bg)
                    capsules.append(bg)
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
                // 数据采集按钮（protocol.md §10）：点击下发 captureStart（10s@5fps），
                // 录制中变红，再点提前停止；采集上传收完后自动复位颜色
                let recBg = makeBtnBg(x: qrBtnW + closeBtnW + btnGap * 2, w: recBtnW)
                let recBtn = makeSymbolButton(symbol: "record.circle", tint: .white,
                                              tooltip: "采集 10 秒识别数据（手机回传，落盘 scenes/）",
                                              bg: recBg)
                recBtn.onClick = { [weak self] in
                    guard let self else { return }
                    if self.capturing {
                        server.sendControl(["type": "captureStop"])
                    } else {
                        // label 只带 Mac 侧已知的标记参数；距离/运动语义由操作者事后改目录名补充
                        self.captureLabel = String(format: "m%d_i%d",
                                                   Int(self.markerSize), Int(self.inset))
                        server.sendControl(["type": "captureStart", "seconds": 10, "fps": 5,
                                            "label": self.captureLabel])
                    }
                    self.capturing.toggle()
                    recBtn.contentTintColor = self.capturing ? .systemRed : .white
                }
                captureButton = recBtn
                // 定位码大小滑杆：拖动实时重建四角标记、更新 Mac 端映射表并把新标定表广播给已连手机。
                // 触控板触觉反馈：每跨 1pt 一次 .generic 轻敲；吸附档位（24/48/64/96）命中时一次
                // .alignment 对位震感（不支持 Force Touch 的硬件系统自动忽略）
                let sliderBg = makeBtnBg(x: qrBtnW + closeBtnW + recBtnW + btnGap * 3, w: sliderW)
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
                    // 标记高度变了，面板跟随下移，始终贴在 id4 白卡下沿之下
                    btnPanel.setFrameOrigin(NSPoint(x: btnPanel.frame.minX,
                                                    y: H - panelTopFromTop() - panelH))
                    sampler.screenCornerMap = Dictionary(uniqueKeysWithValues:
                        self.centers.enumerated().map { (Int32($0.offset), $0.element) })
                    if let data = self.calibPayload(),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        server.sendControl(obj)   // 广播新标定表给所有已连手机（protocol.md §6/§11）
                    }
                    sizeBadge.value = tick
                    print("定位码大小: \(tick)pt（滑杆调整，新标定表已广播）")
                }
                // 定位码不透明度滑杆：与尺寸滑杆同一套交互（5% 刻度轻敲 + 50/75/100% 吸附对位震感）。
                // 只改既有白卡 layer.opacity，无需重建标记；标定表与不透明度无关，不下发
                let alphaBg = makeBtnBg(x: qrBtnW + closeBtnW + recBtnW + btnGap * 3 + sliderW + btnGap,
                                        w: alphaW)
                let alphaSlider = ActionSlider(frame: NSRect(x: 10, y: 8, width: 104, height: 28))
                alphaSlider.minValue = 0.4   // 下限 0.4：再低白环对比度不足，识别率先崩
                alphaSlider.maxValue = 1.0
                alphaSlider.doubleValue = Double(markerAlpha)
                alphaSlider.toolTip = "定位码不透明度（40–100%）：调低更不显眼，但太低会影响识别"
                alphaBg.addSubview(alphaSlider)
                let alphaBadge = SizeBadgeView(frame: NSRect(x: 118, y: 0, width: alphaW - 118 - 8,
                                                             height: panelH))
                alphaBadge.minV = 40; alphaBadge.maxV = 100; alphaBadge.suffix = "%"
                alphaBadge.value = Int((markerAlpha * 100).rounded())
                alphaBadge.toolTip = alphaSlider.toolTip
                alphaBg.addSubview(alphaBadge)
                let alphaDetents: [Double] = [0.5, 0.75, 1.0]
                var lastAlphaTick = Int((markerAlpha * 20).rounded())
                var lastAlphaDetent = alphaDetents.contains(Double(markerAlpha))
                    ? Int(markerAlpha * 100) : -1
                alphaSlider.onChange = { [weak self] v in
                    guard let self else { return }
                    // 吸附：距档位 ≤2% 时吸到档位
                    var snapped = v
                    var hitDetent = -1
                    for d in alphaDetents where abs(v - d) <= 0.02 {
                        snapped = d; hitDetent = Int(d * 100)
                    }
                    let tick = Int((snapped * 20).rounded())   // 5% 粒度
                    if tick != lastAlphaTick {
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                        lastAlphaTick = tick
                    }
                    if hitDetent >= 0 && hitDetent != lastAlphaDetent {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                    lastAlphaDetent = hitDetent
                    let alpha = CGFloat(tick) / 20
                    guard alpha != self.markerAlpha else { return }
                    self.markerAlpha = alpha
                    for card in self.markerCards { card.layer?.opacity = Float(alpha) }
                    alphaBadge.value = Int((alpha * 100).rounded())
                    print("定位码不透明度: \(Int((alpha * 100).rounded()))%（滑杆调整）")
                }
                // 隐藏 UI：全部胶囊隐去，原位留一个更淡的 eye.slash 恢复胶囊（与 iPhone 端眼睛按钮同语义）
                let eyeBg = makeBtnBg(x: qrBtnW + closeBtnW + recBtnW + btnGap * 4 + sliderW + alphaW + btnGap,
                                      w: eyeBtnW)
                let eyeBtn = makeSymbolButton(symbol: "eye", tint: .white,
                                              tooltip: "隐藏面板（原位留恢复按钮）", bg: eyeBg)
                let restoreBg = NSView(frame: eyeBg.frame)
                restoreBg.wantsLayer = true
                restoreBg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
                restoreBg.layer?.cornerRadius = panelH / 2
                btnPanel.contentView?.addSubview(restoreBg)
                let restoreBtn = ActionButton(frame: restoreBg.bounds)
                let restoreCfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
                restoreBtn.image = NSImage(systemSymbolName: "eye.slash",
                                           accessibilityDescription: "显示面板")?
                    .withSymbolConfiguration(restoreCfg)
                restoreBtn.title = ""
                restoreBtn.imagePosition = .imageOnly
                restoreBtn.contentTintColor = NSColor.white.withAlphaComponent(0.85)
                restoreBtn.toolTip = "显示面板"
                restoreBg.addSubview(restoreBtn)
                restoreBg.isHidden = true
                // 隐藏/恢复过渡：100ms 淡出淡入（10ms 在 60fps 下仅 1 帧，等于没有过渡）；
                // 隐藏时恢复胶囊从眼睛按钮原位滑到面板横向居中
                let hideAnim: TimeInterval = 0.1
                let restoreCenterFrame = NSRect(x: panelW / 2 - eyeBtnW / 2, y: 0,
                                                width: eyeBtnW, height: panelH)
                eyeBtn.onClick = {
                    restoreBg.frame = eyeBg.frame
                    restoreBg.alphaValue = 0
                    restoreBg.isHidden = false
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = hideAnim
                        capsules.forEach { $0.animator().alphaValue = 0 }
                        restoreBg.animator().alphaValue = 1
                        restoreBg.animator().frame = restoreCenterFrame
                    }, completionHandler: {
                        capsules.forEach { $0.isHidden = true }
                    })
                }
                restoreBtn.onClick = {
                    capsules.forEach { $0.isHidden = false }
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = hideAnim
                        capsules.forEach { $0.animator().alphaValue = 1 }
                        restoreBg.animator().alphaValue = 0
                        restoreBg.animator().frame = eyeBg.frame
                    }, completionHandler: {
                        restoreBg.isHidden = true
                    })
                }
                btnPanel.orderFrontRegardless()
                objc_setAssociatedObject(win, "btnPanel", btnPanel, .OBJC_ASSOCIATION_RETAIN)
                // 手机端控制消息（protocol.md §7/§8/§11）：配对二维码开关 / 本机识别结果上报 / 鼠标模拟器。
                // src 为链路来源标签（旧链路 tcp / TLV 链路 tlv），只进 localAim CSV 的 src 列
                let handlePhoneControl: ([String: Any], String) -> Void = { [weak self] msg, src in
                    switch msg["type"] as? String {
                    case "mouseDown", "mouseUp":
                        // 横屏鼠标模拟器（§8）：按下/抬起分离注入，支持拖拽；
                        // button=="all" 的 up 是 iPhone 断开前的兜底帧
                        guard let button = msg["button"] as? String else { break }
                        let event = (msg["type"] as? String) == "mouseDown" ? "down" : "up"
                        self?.handleMouseButton(event: event, button: button)
                    case "mouseClick":
                        // 旧协议（§8）：在当前光标位置完整点击一次（需辅助功能权限）
                        guard let button = msg["button"] as? String else { break }
                        self?.warnIfMousePermissionMissing()
                        postMouseClick(button)
                        self?.logMouseEvent(event: "click", button: button, delta: 0)
                        print("MOUSE click: \(button)")
                        DispatchQueue.main.async { [weak self] in
                            self?.debugLabel?.stringValue = "鼠标: \(button) 点击"
                            self?.debugLabel?.textColor = .white
                        }
                    case "mouseScroll":
                        // 横屏鼠标模拟器（§8）：滚轮刻度，正 = 向上滚
                        let delta = msg["delta"] as? Int ?? 0
                        if delta != 0 {
                            self?.warnIfMousePermissionMissing()
                            postMouseScroll(delta)
                            self?.logMouseEvent(event: "scroll", button: "", delta: delta)
                            print("MOUSE scroll: \(delta)")
                            DispatchQueue.main.async { [weak self] in
                                self?.debugLabel?.stringValue = "鼠标: 滚动 \(delta > 0 ? "↑" : "↓")\(abs(delta)) 格"
                                self?.debugLabel?.textColor = .white
                            }
                        }
                    case "togglePairingQR":
                        DispatchQueue.main.async {
                            setQRVisible(self?.qrCard?.isHidden ?? false)
                        }
                    case "disconnect":
                        // 手机主动断开（protocol.md §7）：立即把二维码刷新为当前 IP 并重新显示，等待下一次配对
                        print("手机已断开，重新显示配对二维码")
                        self?.releaseStuckMouseButtons()   // §8：按住中断连，补发 up 防键卡死
                        DispatchQueue.main.async {
                            self?.aimDot?.isHidden = true   // 数据流中断，白点隐藏
                            self?.dotFilter.reset()         // 滤波器随白点隐藏重置，重连后不被过期状态拖走
                            self?.dotNoAimFrames = 0
                            self?.setMarkerActivation([])   // 绿边全部失效
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
                        // 输出等级（WP1 新增可选字段，旧客户端无此字段；只加不删）
                        let quality = msg["quality"] as? String
                        if let x = msg["x"] as? Double, let y = msg["y"] as? Double {
                            print(String(format: "LOCALAIM iPhone: screen=(%.1f, %.1f) markers=%d/8 detected=%@ q=%@ det=%.1fms",
                                         x, y, n, detected.map(String.init).joined(separator: ","),
                                         quality ?? "-", detMs))
                            self?.logLocalAim(markers: n, ids: detected, x: x, y: y,
                                              detectMs: detMs, src: src, quality: quality)
                            let text = String(format: "iPhone 瞄准: (%.1f, %.1f)  标记 %d/8", x, y, n)
                            DispatchQueue.main.async { [weak self] in
                                self?.debugLabel?.stringValue = text
                                self?.debugLabel?.textColor = .white
                                // 白点取 iPhone 数据流的瞄准点（全精度 Double，非 debug 取整值），
                                // 过显示段 AimCoastFilter（插值平滑 + 跳变门，不重复消抖，ADR-014；
                                // 时间戳取到达墙钟）；到达帧 update() 输出是权威位置（WP-L1：
                                // 60Hz 外推定时器只填两次到达之间的显示空窗）。
                                // y 翻转 + 屏内钳制统一走 placeAimDot，此处不再内联换算
                                if self?.aimDot != nil {
                                    self?.dotNoAimFrames = 0
                                    let t = CACurrentMediaTime()
                                    let out = self?.dotFilter.update(raw: CGPoint(x: x, y: y), at: t)
                                    self?.placeAimDot(at: out?.point ?? CGPoint(x: x, y: y))
                                }
                            }
                        } else {
                            let missStr = missing.map(String.init).joined(separator: ",")
                            // 冗余 8 标记下 <4 个匹配才无输出（ADR-007），比旧"缺角即无输出"宽松得多
                            print(String(format: "LOCALAIM iPhone: 检出不足（%d 个，缺 [%@]），无瞄准点 det=%.1fms",
                                         n, missStr, detMs))
                            self?.logLocalAim(markers: n, ids: detected, x: nil, y: nil,
                                              detectMs: detMs, src: src)
                            DispatchQueue.main.async { [weak self] in
                                self?.debugLabel?.stringValue = "iPhone 瞄准: 缺定位码 [\(missStr)]（检出 \(n)/8）"
                                self?.debugLabel?.textColor = .systemYellow
                                // 断流滑行（WP3.2，与 iPhone 段共用 AimCoastFilter）：
                                // 无瞄准点的上报帧白点按速度衰减外推继续滑行，最多
                                // maxCoastFrames 帧（默认 5 ≈ 330ms@15Hz）才隐藏，
                                // 不再一丢就隐（旧行为：单帧掉检白点即消失）
                                let t = CACurrentMediaTime()
                                if let out = self?.dotFilter.update(raw: nil, at: t),
                                   self?.aimDot != nil {
                                    self?.placeAimDot(at: out.point)
                                } else {
                                    self?.aimDot?.isHidden = true   // 滑行预算耗尽，白点隐藏
                                }
                                // 连续 10 帧无瞄准点才重置滤波器：单帧掉检不重置，
                                // 恢复后白点从滤波状态平滑出现而非跳变
                                if let s = self {
                                    s.dotNoAimFrames += 1
                                    if s.dotNoAimFrames >= 10 {
                                        s.dotFilter.reset()
                                        s.dotNoAimFrames = 0
                                    }
                                }
                            }
                        }
                    default:
                        break
                    }
                }
                server.onControl = { msg in handlePhoneControl(msg, "tlv") }
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
                // 采集回传并入主 TLV 连接（type 10/11，protocol.md §11；旧独立端口服务已随 P3 拆除）
                server.sessionInfo = { [weak self, sampler] in
                    guard let self else { return [:] }
                    var map: [String: [Double]] = [:]
                    for (k, v) in sampler.screenCornerMap {
                        map["\(k)"] = [Double(v.x), Double(v.y)]
                    }
                    return ["label": self.captureLabel,
                            "markerSize": Double(self.markerSize),
                            "inset": Double(self.inset),
                            "screenW": Double(self.screenW), "screenH": Double(self.screenH),
                            "screenCornerMap": map]
                }
                server.onCaptureDone = { [weak self] _ in
                    self?.capturing = false
                    self?.captureButton?.contentTintColor = .white
                }
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

        // MARK: WP1 仿射兜底 + 断帧滑行（合成匹配点直注 processMatches，无需图像，ADR-013）
        // 近距瞄角场景：逻辑屏 1728×1117，视野只覆盖左上角簇（角标 id0 + 上中 id4 + 左中 id7，
        // 即方案 §0 统计的 L 形三点簇）；帧 1280×720，帧上位置 = 屏幕坐标 × 0.8 + 偏移
        do {
            let loc = ScreenLocalizer()
            loc.screenCornerMap = [0: CGPoint(x: 36, y: 36), 4: CGPoint(x: 864, y: 36),
                                   7: CGPoint(x: 36, y: 558.5)]
            func synth(_ p: CGPoint, s: Double, off: CGPoint) -> CGPoint {
                CGPoint(x: p.x * s + off.x, y: p.y * s + off.y)
            }
            let dst3 = [loc.screenCornerMap[0]!, loc.screenCornerMap[4]!, loc.screenCornerMap[7]!]
            // 场景 1：瞄点在簇内（帧中心映射到屏幕 (737.5, 375)，三点外接框内）→ 仿射输出，误差 < 5pt
            let src3 = dst3.map { synth($0, s: 0.8, off: CGPoint(x: 50, y: 60)) }
            let truth = CGPoint(x: (640 - 50) / 0.8, y: (360 - 60) / 0.8)
            guard let (aim3, q3) = loc.solveAim(src: src3, dst: dst3,
                                                frameCenter: CGPoint(x: 640, y: 360)) else {
                print("自检失败: 三点簇（簇内瞄点）仿射兜底无输出"); exit(1)
            }
            let err3 = hypot(aim3.x - truth.x, aim3.y - truth.y)
            print(String(format: "  三点簇仿射兜底: quality=%@ 误差 %.2fpt（期望≈(%.1f, %.1f)）",
                         q3.rawValue, err3, truth.x, truth.y))
            guard q3 == .affine, err3 < 5 else {
                print("自检失败: 三点簇仿射 quality=\(q3) 误差 \(err3)pt"); exit(1)
            }
            // 场景 2：瞄点强外推（帧中心映射到屏幕 (-575, -300)，超出 1.5× 凸包护栏）→ 必须无解
            let src3b = dst3.map { synth($0, s: 0.8, off: CGPoint(x: 1100, y: 600)) }
            guard loc.solveAim(src: src3b, dst: dst3, frameCenter: CGPoint(x: 640, y: 360)) == nil else {
                print("自检失败: 护栏外强外推仍给出输出（发散护栏失效）"); exit(1)
            }
            print("  护栏外强外推: 正确拒绝输出（1.5× 凸包护栏）")
            // 场景 3：断帧滑行——先喂一帧 4 对有效解，再连续喂无解帧：
            // 前 maxCoastFrames（5）帧有 coast 输出，第 6 帧起 nil
            let loc2 = ScreenLocalizer()
            loc2.screenCornerMap = [0: CGPoint(x: 36, y: 36), 1: CGPoint(x: 1692, y: 36),
                                    2: CGPoint(x: 1692, y: 1081), 3: CGPoint(x: 36, y: 1081)]
            let src4 = [0, 1, 2, 3].map { synth(loc2.screenCornerMap[$0]!, s: 0.5,
                                                off: CGPoint(x: 100, y: 100)) }
            let dst4 = [0, 1, 2, 3].map { loc2.screenCornerMap[$0]! }
            let center = CGPoint(x: 640, y: 360)
            let (aim0, q0) = loc2.processMatches(src: src4, dst: dst4, frameCenter: center,
                                                 timestamp: 0)
            guard aim0 != nil, q0 == .homography else {
                print("自检失败: 滑行前置帧（4 对单应）无输出"); exit(1)
            }
            var coastFrames = 0
            for i in 1...6 {
                let (aimI, qI) = loc2.processMatches(src: [], dst: [], frameCenter: center,
                                                     timestamp: Double(i) / 15.0)
                if let a = aimI {
                    guard qI == .coast else {
                        print("自检失败: 滑行帧 quality=\(String(describing: qI))，期望 coast"); exit(1)
                    }
                    // 静止相机滑行输出应保持原位（速度≈0 不漂移）
                    guard hypot(a.x - aim0!.x, a.y - aim0!.y) < 1 else {
                        print("自检失败: 静止滑行漂移超过 1pt"); exit(1)
                    }
                    coastFrames += 1
                }
            }
            guard coastFrames == 5 else {
                print("自检失败: 滑行帧数 \(coastFrames)，期望 5（默认 maxCoastFrames）"); exit(1)
            }
            print("  断帧滑行: 5 帧 coast 输出（静止无漂移），第 6 帧起正确置 nil")
        }
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

if CommandLine.arguments.contains("--swift-seq") {
    setbuf(stdout, nil)
    // 序列基准（Phase 1.3 验收）：按序对一组场景图（shell glob 展开成多个参数）
    // 跑 ScreenLocalizer，同帧对比未滤波 / One Euro 滤波两条轨迹的静止 σ。
    // 真值映射表取首个同名 JSON 的 logical（静止组几何固定）；时间戳按 30fps 合成，
    // 与相机帧率一致——滤波效果依赖 dt，墙钟（检测耗时长）会低估消抖能力
    let args = Array(CommandLine.arguments.drop(while: { $0 != "--swift-seq" }).dropFirst())
    let files = args.filter { $0.hasSuffix(".png") }
    // 可选 --cutoff C --beta B：扫描滤波参数（验收调参用，默认 1.0 / 0.5）
    func opt(_ name: String, _ fallback: Double) -> Double {
        guard let i = args.firstIndex(of: name), args.count > i + 1,
              let v = Double(args[i + 1]) else { return fallback }
        return v
    }
    let cutoff = opt("--cutoff", 1.0), beta = opt("--beta", 0.5)
    let raw = ScreenLocalizer()     // 未滤波对照
    raw.aimFilterEnabled = false
    let flt = ScreenLocalizer()
    flt.aimFilter.params.minCutoff = cutoff
    flt.aimFilter.params.beta = beta
    var mapLoaded = false
    var rawAims: [CGPoint] = [], fltAims: [CGPoint] = []
    for (i, f) in files.enumerated() {
        if !mapLoaded {
            let js = (f as NSString).deletingPathExtension + ".json"
            if let d = FileManager.default.contents(atPath: js),
               let gt = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let lg = gt["logical"] as? [String: [Double]] {
                let map = lg.reduce(into: [Int: CGPoint]()) {
                    $0[Int($1.key) ?? -1] = CGPoint(x: $1.value[0], y: $1.value[1])
                }
                raw.screenCornerMap = map
                flt.screenCornerMap = map
                mapLoaded = true
            }
        }
        guard let (data, w, h) = loadBGRA(from: f) else { continue }
        let ts = Double(i) / 30.0   // 合成 30fps 时间轴
        let r0 = data.withUnsafeBytes {
            raw.localize(bgra: $0.baseAddress!, width: w, height: h, bytesPerRow: w * 4,
                         timestamp: ts)
        }
        let r1 = data.withUnsafeBytes {
            flt.localize(bgra: $0.baseAddress!, width: w, height: h, bytesPerRow: w * 4,
                         timestamp: ts)
        }
        if let a = r0.aim { rawAims.append(a) }
        if let a = r1.aim { fltAims.append(a) }
    }
    func sigmaR(_ pts: [CGPoint]) -> Double {
        guard pts.count > 1 else { return 0 }
        let n = Double(pts.count)
        let mx = pts.map(\.x).reduce(0, +) / n, my = pts.map(\.y).reduce(0, +) / n
        let sx = sqrt(pts.map { ($0.x - mx) * ($0.x - mx) }.reduce(0, +) / (n - 1))
        let sy = sqrt(pts.map { ($0.y - my) * ($0.y - my) }.reduce(0, +) / (n - 1))
        return hypot(sx, sy)
    }
    print(String(format: "序列 %d 帧（cutoff=%.2f beta=%.2f）：未滤波 σr=%.4fpt（n=%d） vs One Euro σr=%.4fpt（n=%d）",
                 files.count, cutoff, beta, sigmaR(rawAims), rawAims.count,
                 sigmaR(fltAims), fltAims.count))
    exit(0)
}

if CommandLine.arguments.contains("--filter-self-test") {
    setbuf(stdout, nil)
    // WP3 滤波层验收（确定性合成信号，方案 §3.3 / ADR-014）：静止 σ 回归、单帧跳变门、
    // 断流滑行、预设横扫滞后对比。时间轴 15Hz（真实识别/上报节奏；静止 σ 另报 30Hz
    // 与 README 既有基准对齐）；噪声为固定种子 xorshift64* + Box-Muller 高斯，跨平台可复现
    var rngState: UInt64 = 0x9E3779B97F4A7C15
    func uniform() -> Double {
        rngState ^= rngState >> 12; rngState ^= rngState << 25; rngState ^= rngState >> 27
        return Double((rngState &* 0x2545F4914F6CDD1D) >> 11) / Double(1 << 53)
    }
    func gauss() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
    func sigmaR(_ pts: [CGPoint]) -> Double {
        guard pts.count > 1 else { return 0 }
        let n = Double(pts.count)
        let mx = pts.map(\.x).reduce(0, +) / n, my = pts.map(\.y).reduce(0, +) / n
        let sx = sqrt(pts.map { ($0.x - mx) * ($0.x - mx) }.reduce(0, +) / (n - 1))
        let sy = sqrt(pts.map { ($0.y - my) * ($0.y - my) }.reduce(0, +) / (n - 1))
        return hypot(sx, sy)
    }
    func fail(_ msg: String) -> Never { print("滤波自检失败: \(msg)"); exit(1) }

    // ① 静止 σ 回归：输入 σr=0.171pt（0.121pt/轴，复刻 README bench 基准的原始识别噪声：
    // 「24pt 静止 σr 0.171 → 0.080pt」）。门限开启不得劣化消抖，30Hz 时间轴与该基准对齐
    let noiseAxis = 0.171 / sqrt(2.0)
    for fps in [30.0, 15.0] {
        let on = AimCoastFilter(params: AimFilterPreset.daily.phone)
        var offP = AimFilterPreset.daily.phone; offP.gateK = nil
        let off = AimCoastFilter(params: offP)
        var outsOn: [CGPoint] = [], outsOff: [CGPoint] = []
        for i in 0..<300 {
            let t = Double(i) / fps
            let raw = CGPoint(x: 500 + noiseAxis * gauss(), y: 400 + noiseAxis * gauss())
            if let o = on.update(raw: raw, at: t), i >= 60 { outsOn.append(o.point) }
            if let o = off.update(raw: raw, at: t), i >= 60 { outsOff.append(o.point) }
        }
        let sOn = sigmaR(outsOn), sOff = sigmaR(outsOff)
        print(String(format: "  ① 静止 σ（%dHz）: 跳变门开 σr=%.3fpt / 关 σr=%.3fpt",
                     Int(fps), sOn, sOff))
        if fps == 30, sOn > 0.09 { fail("30Hz 静止 σr \(sOn)pt 劣化于现状基准 0.080pt") }
        if sOn > sOff * 1.05 { fail("跳变门显著劣化静止 σ（\(sOn) vs \(sOff)）") }
    }

    // ② 单帧 15pt 跳变（RANSAC 漏网离群模拟）：跳变门开时白点不甩（最大偏离 < 5pt）
    do {
        let on = AimCoastFilter(params: AimFilterPreset.daily.phone)
        var offP = AimFilterPreset.daily.phone; offP.gateK = nil
        let off = AimCoastFilter(params: offP)
        var devOn = 0.0, devOff = 0.0
        for i in 0..<300 {
            let t = Double(i) / 15.0
            var raw = CGPoint(x: 500 + noiseAxis * gauss(), y: 400 + noiseAxis * gauss())
            if i == 150 { raw.x += 15 }   // 单帧人工跳变
            if let o = on.update(raw: raw, at: t), i > 100 {
                devOn = max(devOn, hypot(o.point.x - 500, o.point.y - 400))
            }
            if let o = off.update(raw: raw, at: t), i > 100 {
                devOff = max(devOff, hypot(o.point.x - 500, o.point.y - 400))
            }
        }
        print(String(format: "  ② 单帧 15pt 跳变: 最大偏离 门限开 %.2fpt / 门限关 %.2fpt", devOn, devOff))
        if devOn >= 5 { fail("跳变门开仍甩出 \(devOn)pt") }
        if devOn > devOff / 2 { fail("跳变门未显著抑制甩动（开 \(devOn) vs 关 \(devOff)）") }
    }

    // ③ 断流滑行：300pt/s 匀速移动中断流 3 帧，白点须继续滑行不消失、方向不回退；
    // 断流 7 帧时第 6 帧起（超 maxCoastFrames=5）消失
    do {
        let f = AimCoastFilter(params: AimFilterPreset.daily.phone)
        func truth(_ i: Int) -> CGPoint {
            let t = Double(i) / 15.0
            return t < 4 ? CGPoint(x: 100, y: 400) : CGPoint(x: 100 + 300 * (t - 4), y: 400)
        }
        var glideOK = true, coastNonNil = 0, prevX = -Double.infinity
        var nilAt: [Int] = []
        var prev: CGPoint?, maxStep = 0.0
        for i in 0..<300 {
            let t = Double(i) / 15.0
            let drop3 = (100...102).contains(i)      // 3 帧断流
            let drop7 = (200...206).contains(i)      // 7 帧断流
            var raw: CGPoint? = nil
            if !drop3, !drop7 {
                let p = truth(i)
                raw = CGPoint(x: p.x + 0.05 * gauss(), y: p.y + 0.05 * gauss())
            }
            let out = f.update(raw: raw, at: t)
            if drop3 {
                if let o = out {
                    coastNonNil += 1
                    if o.point.x < prevX - 0.01 { glideOK = false }
                    prevX = o.point.x
                } else { glideOK = false }
            }
            if drop7, out == nil { nilAt.append(i) }
            if (100...110).contains(i), let o = out {
                if let p = prev { maxStep = max(maxStep, hypot(o.point.x - p.x, o.point.y - p.y)) }
                prev = o.point
            }
        }
        print(String(format: "  ③ 断流滑行: 3 帧断流滑行输出 %d/3 帧（匀速方向保持 %@），断流区最大单帧步进 %.1fpt；7 帧断流于第 %@ 帧起消失",
                     coastNonNil, glideOK ? "✓" : "✗", maxStep,
                     nilAt.map { $0 - 200 + 1 }.map(String.init).joined(separator: ",")))
        if coastNonNil != 3 || !glideOK { fail("3 帧断流内白点消失或回退") }
        if nilAt != [205, 206] { fail("7 帧断流消失时机 \(nilAt)，期望第 6/7 帧（205/206）") }
    }

    // ④ 预设横扫滞后：±200pt 正弦横扫（0.5Hz，峰值速度 628pt/s），
    // 「疾速响应」平均误差须明显小于「稳如三脚架」
    do {
        func sweepErr(_ preset: AimFilterPreset) -> Double {
            let f = AimCoastFilter(params: preset.phone)
            var errs: [Double] = []
            for i in 0..<600 {
                let t = Double(i) / 15.0
                let tx = 864 + 200 * sin(2 * .pi * 0.5 * t)
                let raw = CGPoint(x: tx + noiseAxis * gauss(), y: 558.5 + noiseAxis * gauss())
                if let o = f.update(raw: raw, at: t), i >= 120 {
                    errs.append(hypot(o.point.x - tx, o.point.y - 558.5))
                }
            }
            return errs.reduce(0, +) / Double(errs.count)
        }
        let eStable = sweepErr(.stable), eDaily = sweepErr(.daily), eFast = sweepErr(.fast)
        print(String(format: "  ④ 横扫平均误差: 稳如三脚架 %.2fpt / 日常跟手 %.2fpt / 疾速响应 %.2fpt",
                     eStable, eDaily, eFast))
        if eFast >= eStable * 0.7 { fail("疾速响应(\(eFast)pt) 未明显小于稳如三脚架(\(eStable)pt)") }
    }
    // ⑤ 显示外推（WP-L1，ADR-015）：displayExtrapolation 是只读匀速死推算 + 120ms 封顶。
    // 匀速 300pt/s（真实横扫量级）样本后 +33/+66ms 外推点与真值轨迹误差 < 1pt；
    // 静止样本外推漂移 < 0.1pt；超 120ms 时距外推值 = 封顶点（原地保持）；
    // 未初始化返回 nil。注意本服务的是 Mac 显示段，滤波器用 macDisplay 预设
    do {
        if AimCoastFilter().displayExtrapolation(at: 1.0) != nil {
            fail("未初始化滤波器外推应返回 nil")
        }
        // 匀速段：静止 2s 后 300pt/s 匀速（真值形态同 ③），充分稳定后取最后时刻外推
        let f = AimCoastFilter(params: AimFilterPreset.daily.macDisplay)
        func truth(_ t: Double) -> CGPoint {
            t < 2 ? CGPoint(x: 100, y: 400) : CGPoint(x: 100 + 300 * (t - 2), y: 400)
        }
        var lastT = 0.0
        for i in 0..<600 {
            let t = Double(i) / 15.0
            let p = truth(t)
            _ = f.update(raw: CGPoint(x: p.x + 0.05 * gauss(), y: p.y + 0.05 * gauss()), at: t)
            lastT = t
        }
        var maxErr = 0.0
        for dt in [0.033, 0.066] {
            guard let p = f.displayExtrapolation(at: lastT + dt) else {
                fail("匀速样本后外推返回 nil")
            }
            let q = truth(lastT + dt)
            maxErr = max(maxErr, hypot(p.x - q.x, p.y - q.y))
        }
        // 静止段：Mac 显示段输入是 iPhone 段已消抖的信号，静止残差 σr≈0.08pt 级
        // （tuning 文档基准），喂 0.05pt/轴噪声贴近该量级而非原始识别噪声
        f.reset()
        for i in 0..<300 {
            let t = Double(i) / 15.0
            _ = f.update(raw: CGPoint(x: 500 + 0.05 * gauss(), y: 400 + 0.05 * gauss()), at: t)
            lastT = t
        }
        var maxDrift = 0.0
        for dt in [0.033, 0.066, AimCoastFilter.maxDisplayExtrapolation] {
            guard let p = f.displayExtrapolation(at: lastT + dt),
                  let p0 = f.displayExtrapolation(at: lastT) else {
                fail("静止样本后外推返回 nil")
            }
            maxDrift = max(maxDrift, hypot(p.x - p0.x, p.y - p0.y))
        }
        // 封顶：超 120ms 时距的外推值必须等于封顶点（原地保持，不再继续前进）
        guard let pCap = f.displayExtrapolation(at: lastT + AimCoastFilter.maxDisplayExtrapolation),
              let pFar = f.displayExtrapolation(at: lastT + 10.0) else {
            fail("封顶检查外推返回 nil")
        }
        print(String(format: "  ⑤ 显示外推: 匀速300pt/s +33/+66ms 最大误差 %.3fpt；静止外推漂移 %.3fpt；超 120ms 时距 %@封顶点",
                     maxErr, maxDrift, pFar == pCap ? "等于" : "偏离"))
        if maxErr >= 1.0 { fail("匀速外推误差 \(maxErr)pt ≥ 1pt") }
        if maxDrift >= 0.1 { fail("静止外推漂移 \(maxDrift)pt ≥ 0.1pt") }
        if pFar != pCap { fail("超 120ms 时距外推值 \(pFar) ≠ 封顶点 \(pCap)") }
    }
    print("滤波自检通过 ✅")
    exit(0)
}

if let ri = CommandLine.arguments.firstIndex(of: "--replay"),
   CommandLine.arguments.count > ri + 1 {
    setbuf(stdout, nil)
    // 采集回放（protocol.md §10）：逐帧重跑纯 Swift 检测器 + OpenCV 参照，
    // 与录制时的线上结果对比。用于真机数据上的离线调参（参数覆盖见下）与 A/B。
    let dir = CommandLine.arguments[ri + 1]
    func optD(_ name: String) -> Double? {
        guard let i = CommandLine.arguments.firstIndex(of: name),
              CommandLine.arguments.count > i + 1 else { return nil }
        return Double(CommandLine.arguments[i + 1])
    }
    let localizer = ScreenLocalizer()
    localizer.aimFilterEnabled = false   // 回放测原始检测质量；滤波效果走 --swift-seq
    if let v = optD("--min-cell-gap") { localizer.detector.minCellGap = v }
    if let v = optD("--thresh-c") { localizer.detector.thresholdC = v }
    if let v = optD("--window"), let iv = Int(exactly: v) { localizer.detector.windowSize = iv }
    if CommandLine.arguments.contains("--no-refine") { localizer.detector.subpixelRefine = false }
    // 映射表来自 session.json（采集时 Mac 侧真实标定）；缺失则只出检出率，不出 aim
    if let d = FileManager.default.contents(atPath: dir + "/session.json"),
       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       let m = obj["screenCornerMap"] as? [String: [Double]] {
        localizer.screenCornerMap = m.reduce(into: [:]) {
            guard let id = Int($1.key), $1.value.count == 2 else { return }
            $0[id] = CGPoint(x: $1.value[0], y: $1.value[1])
        }
    }
    guard let metaRaw = FileManager.default.contents(atPath: dir + "/meta.jsonl"),
          let metaText = String(data: metaRaw, encoding: .utf8) else {
        fputs("回放失败: \(dir)/meta.jsonl 不存在\n", stderr); exit(1)
    }
    let bridge = OpenCVBridge()
    var frames = 0
    var onlineHit: [Int: Int] = [:], offHit: [Int: Int] = [:], cvHit: [Int: Int] = [:]
    var centerErrs: [Double] = []
    var aims: [CGPoint] = []
    // WP1 验收统计：匹配对数分布、输出等级分布、恰好 3 对匹配帧的仿射兜底转化率
    var matchHist: [Int: Int] = [:]
    var qualityHist: [String: Int] = [:]
    var threeMatchFrames = 0, threeMatchAim = 0
    var csv = ["frame,id,online,offline,cv,offline_cx,offline_cy,cv_cx,cv_cy,center_err_px"]
    for line in metaText.split(separator: "\n") {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              obj["kind"] as? String == "frame",
              let seq = obj["seq"] as? Int else { continue }
        let png = String(format: "%@/frames/%04d.png", dir, seq)
        guard let (data, w, h) = loadBGRA(from: png) else { continue }
        frames += 1
        let result = data.withUnsafeBytes {
            localizer.localize(bgra: $0.baseAddress!, width: w, height: h, bytesPerRow: w * 4)
        }
        let cv = data.withUnsafeBytes {
            bridge.detectMarkers(inBGRABuffer: $0.baseAddress!, width: Int32(w), height: Int32(h))
        }
        let onlineIDs: Set<Int> = Set(((obj["markers"] as? [[String: Any]]) ?? [])
            .compactMap { $0["id"] as? Int })
        let offMap = result.markers.reduce(into: [Int: CGPoint]()) { $0[$1.id] = $1.center }
        let cvMap = cv.reduce(into: [Int: CGPoint]()) { $0[Int($1.markerId)] = $1.center }
        if let aim = result.aim { aims.append(aim) }
        let matched = offMap.keys.filter { localizer.screenCornerMap[$0] != nil }.count
        matchHist[matched, default: 0] += 1
        if let q = result.quality { qualityHist[q.rawValue, default: 0] += 1 }
        if matched == 3 { threeMatchFrames += 1; if result.aim != nil { threeMatchAim += 1 } }
        for id in 0...7 {
            let on = onlineIDs.contains(id), off = offMap[id] != nil, c = cvMap[id] != nil
            if on { onlineHit[id, default: 0] += 1 }
            if off { offHit[id, default: 0] += 1 }
            if c { cvHit[id, default: 0] += 1 }
            var err = ""
            if let o = offMap[id], let v = cvMap[id] {
                let e = hypot(o.x - v.x, o.y - v.y)
                centerErrs.append(e)
                err = String(format: "%.2f", e)
            }
            csv.append(String(format: "%d,%d,%d,%d,%d,%.2f,%.2f,%.2f,%.2f,%@",
                              seq, id, on ? 1 : 0, off ? 1 : 0, c ? 1 : 0,
                              offMap[id]?.x ?? 0, offMap[id]?.y ?? 0,
                              cvMap[id]?.x ?? 0, cvMap[id]?.y ?? 0, err))
        }
    }
    // 汇总：命中率（线上/离线/参照）、中心误差（离线 vs OpenCV 参照）、aim σ、拒绝直方图
    print("== 回放汇总（\(dir)）==")
    print("帧数: \(frames)")
    print("id | 线上 | 离线 | OpenCV")
    for id in 0...7 {
        print(String(format: "%2d | %3.0f%% | %3.0f%% | %3.0f%%", id,
                     Double(onlineHit[id] ?? 0) / Double(max(frames, 1)) * 100,
                     Double(offHit[id] ?? 0) / Double(max(frames, 1)) * 100,
                     Double(cvHit[id] ?? 0) / Double(max(frames, 1)) * 100))
    }
    if !centerErrs.isEmpty {
        let sorted = centerErrs.sorted()
        print(String(format: "中心误差（离线 vs OpenCV）: p50=%.2fpx p95=%.2fpx max=%.2fpx（n=%d）",
                     sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)],
                     sorted.last!, sorted.count))
    }
    if aims.count > 1 {
        let n = Double(aims.count)
        let mx = aims.map(\.x).reduce(0, +) / n, my = aims.map(\.y).reduce(0, +) / n
        let sx = sqrt(aims.map { ($0.x - mx) * ($0.x - mx) }.reduce(0, +) / (n - 1))
        let sy = sqrt(aims.map { ($0.y - my) * ($0.y - my) }.reduce(0, +) / (n - 1))
        print(String(format: "aim σ（未滤波，n=%d）: σx=%.3fpt σy=%.3fpt σr=%.3fpt",
                     aims.count, sx, sy, hypot(sx, sy)))
    }
    // WP1 验收：匹配对数分布 + 输出等级分布 + 三点簇帧仿射转化率（目标 ≈100%，护栏外零输出）
    print("匹配对数分布: " + matchHist.sorted { $0.key < $1.key }
        .map { "\($0.key)对:\($0.value)帧" }.joined(separator: " "))
    if !qualityHist.isEmpty {
        print("输出等级分布: " + qualityHist.sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }.joined(separator: " "))
    }
    if threeMatchFrames > 0 {
        print(String(format: "三点簇帧转化率: %d/%d = %.0f%%（仿射兜底，护栏外应无输出）",
                     threeMatchAim, threeMatchFrames,
                     Double(threeMatchAim) / Double(threeMatchFrames) * 100))
    }
    let hist = localizer.detector.rejectHistogram.sorted { $0.value > $1.value }
    if !hist.isEmpty {
        print("拒绝直方图: " + hist.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }
    try? (csv.joined(separator: "\n") + "\n")
        .write(toFile: dir + "/replay.csv", atomically: true, encoding: .utf8)
    print("replay.csv 已写入 \(dir)")
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
    // 标记边长（点），默认 48pt（ADR-010）：24pt 是 1280 宽降采样本机采屏的实测可靠下限，
    // 但手机远距离实测中边中点标记掉检严重（真机验证 48pt 检出 >6/8）；
    // 识别不稳仍可调大，如 --marker-size 64
    var size: CGFloat = 48
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
    // --aim-cursor: 手机帧识别出的瞄准点直接绑定鼠标光标位置（protocol.md §5）
    let aimCursor = CommandLine.arguments.contains("--aim-cursor")
    // WP3.4 口语化调参（逐项说明见 docs/aim-filter-tuning.md）：
    // --filter-preset stable|daily|fast 选预设档（同时经 calib 下发 iPhone 识别段），
    // 四个单项旋钮只覆盖 Mac 显示段参数（iPhone 段跟预设走）
    func optD(_ name: String) -> Double? {
        guard let i = CommandLine.arguments.firstIndex(of: name),
              CommandLine.arguments.count > i + 1 else { return nil }
        return Double(CommandLine.arguments[i + 1])
    }
    var preset = AimFilterPreset.daily
    if let i = CommandLine.arguments.firstIndex(of: "--filter-preset"),
       CommandLine.arguments.count > i + 1,
       let p = AimFilterPreset(rawValue: CommandLine.arguments[i + 1]) {
        preset = p
    }
    var dotParams = preset.macDisplay
    if let v = optD("--dot-min-cutoff") { dotParams.minCutoff = v }   // 「静止时白点有多稳」0.4–2.0
    if let v = optD("--dot-beta") { dotParams.beta = v }              // 「甩动时有多跟手」0.2–1.5
    if let v = optD("--dot-coast-frames") { dotParams.maxCoastFrames = max(0, Int(v)) }  // 「断识后续滑多久」0–10
    if let v = optD("--dot-gate-k") { dotParams.gateK = v > 0 ? v : nil }  // 「跳变过滤多严格」1.5–4.0 / 0=关
    // 顶层全局强引用持有 Calibrator，保证滑杆/按钮闭包里的 weak self 在整个生命周期有效
    let calibrator = Calibrator(markerSize: size, inset: inset, pad: pad, servePort: servePort,
                                aimCursor: aimCursor)
    calibrator.filterPreset = preset
    calibrator.dotFilter.params = dotParams
    if preset != .daily || dotParams != AimFilterPreset.daily.macDisplay {
        print("滤波调参: preset=\(preset.rawValue) Mac显示段 minCutoff=\(dotParams.minCutoff) beta=\(dotParams.beta) coast=\(dotParams.maxCoastFrames)帧 gateK=\(dotParams.gateK.map { String($0) } ?? "关")")
    }
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
/// button 字符串 → CGEvent 类型映射（"left" / "right" / "middle"）
private func mouseEventTypes(_ button: String) -> (CGEventType, CGEventType, CGMouseButton) {
    switch button {
    case "right":  return (.rightMouseDown, .rightMouseUp, .right)
    case "middle": return (.otherMouseDown, .otherMouseUp, .center)
    default:       return (.leftMouseDown, .leftMouseUp, .left)
    }
}

/// 在当前光标位置按下指定键（不弹起，配合 postMouseUp 支持拖拽）。
/// 需 系统设置 > 隐私与安全性 > 辅助功能 授权，否则事件被系统静默丢弃
func postMouseDown(_ button: String) {
    guard let pos = CGEvent(source: nil)?.location else { return }
    let (downType, _, cgButton) = mouseEventTypes(button)
    CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: pos, mouseButton: cgButton)?
        .post(tap: .cghidEventTap)
}

/// 在当前光标位置抬起指定键
func postMouseUp(_ button: String) {
    guard let pos = CGEvent(source: nil)?.location else { return }
    let (_, upType, cgButton) = mouseEventTypes(button)
    CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: pos, mouseButton: cgButton)?
        .post(tap: .cghidEventTap)
}

/// 在当前光标位置点击一次（旧协议 mouseClick，向后兼容）。button: "left" / "right" / "middle"
func postMouseClick(_ button: String) {
    postMouseDown(button)
    postMouseUp(button)
}

/// 滚轮滚动。delta 为刻度（行）数，正 = 向上滚（与手机端手指上滑同向）
func postMouseScroll(_ delta: Int) {
    CGEvent(scrollWheelEvent2Source: nil, units: .line,
            wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0)?
        .post(tap: .cghidEventTap)
}

RunLoop.main.run()
