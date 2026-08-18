//
//  TLVTransport.swift
//  AimPhone（iOS 端）— TLV 消息流传输：单连接承载视频帧 / 控制消息 / 采集上传
//
//  关键约束：Network.framework 26+ 结构化并发 API（NetworkConnection + 内置 TLV framer，
//  部署目标 iOS 26，无 #available 双栈）；线上格式见 docs/protocol.md §11。
//  看门狗语义与旧 NWConnection 路径一致（5s×6 重试，本地网络授权弹窗期连接会永久
//  卡死必须重启，protocol.md §4）；回调全部主线程派发。与 CameraStreamer 旧路径并存
//  于过渡期，旧实现拆除见 transport-26-plan P3。
//

import Foundation
import Network
#if canImport(UIKit)
import UIKit   // UIDevice（采集 session 记录系统版本）
#endif
// NOTE: AimPhone 把 ScreenAimCore 源码直接编进 App（同模块无需 import）；
// Mac 端/命令行测试台里它是独立模块，需要显式 import
#if canImport(ScreenAimCore)
import ScreenAimCore
#endif

/// 采集回传限速目标（P1 Step 1，tlv-blocking-optimization-plan §2.1），单位 B/s。
/// 依据：12MB/s ≈ 局域网 Wi-Fi 典型可用带宽（40~80MB/s 实测区间，802.11ax 近距离）
/// 的 1/4～1/3——35–75MB/段的 PNG 回传若不限速会把单连接上的视频帧/控制消息压在
/// 发送缓冲里（字节级队头阻塞）；留 2/3 余量给视频（15fps×~100KB ≈ 1.5MB/s）与控制。
/// 只在 uploadCapture 回传循环内生效，不影响视频/控制正常路径；
/// 真机验收门（plan §2.1）不达标则推翻本方案、退回 Step 2 独立连接
private let captureUploadRate: Double = 12 * 1_000_000

/// TLV 单连接传输（Mac 端 FrameServerV2 的客户端对偶）。
/// type 0 视频帧 / type 1 控制 JSON（双向）/ type 2 Codable AimMessage 信封（双向）/
/// type 10、11 采集上传，消息边界与长度校验由框架托管；`try await send` 挂起即背压。
final class TLVTransport {
    /// 连接状态事件（主线程派发；文案与旧路径保持一致，UI 直接展示）
    enum Event {
        case ready(label: String)        // 连接建立
        case waiting                     // 等待网络（可能在本地网络授权弹窗期）
        case retrying(text: String)      // 重试进行中（含 1s 延迟重试与看门狗超时重试）
        case failed(text: String)        // 终态失败（重试耗尽）
        case disconnected(text: String)  // 已建立的连接意外断开
    }
    var onEvent: ((Event) -> Void)?
    /// Mac → iPhone 控制消息（type 1 原始 JSON 字节；主线程派发）
    var onControl: ((Data) -> Void)?
    /// Mac → iPhone 结构化消息（TLV type 2 Codable 信封 AimMessage，protocol.md §11；
    /// 主线程派发；解码失败的消息忽略，不破坏连接）
    var onMessage: ((AimMessage) -> Void)?

    private(set) var isConnected = false
    /// 最近一次连接目标（fast 时敏通道在主连接就绪后复用同一端点开第二连接，ADR-017）
    private(set) var lastEndpoint: (endpoint: NWEndpoint, label: String)?

    private var connection: NetworkConnection<TLV>?
    private var readTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    /// 连接身份代数：每次新建连接 +1，旧连接的迟到回调经代数比对失效
    ///（新 NetworkConnection 无指针可比，NOTE: 与旧路径 `connection === conn` 同目的）
    private var generation = 0
    private var retryCount = 0

    // MARK: 连接

    func connect(endpoint: NWEndpoint, label: String) {
        retryCount = 0
        lastEndpoint = (endpoint, label)
        startConnection(endpoint: endpoint, label: label)
    }

    func connect(host: String, port: UInt16) {
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        connect(endpoint: .hostPort(host: NWEndpoint.Host(host), port: p),
                label: "\(host):\(port)")
    }

    private func startConnection(endpoint: NWEndpoint, label: String) {
        generation += 1
        let gen = generation
        teardownConnection()
        let conn = NetworkConnection(to: endpoint) {
            // NOTE: 与服务端一致显式开 noDelay（协议 §11：控制小道消息不允许 Nagle 攒批）
            TLV { TCP().noDelay(true) }
        }
        connection = conn

        conn.onStateUpdate { [weak self] _, state in
            DispatchQueue.main.async {
                self?.handleState(state, gen: gen, endpoint: endpoint, label: label)
            }
        }

        // 接收循环：Mac 下行为 type 1 控制 JSON + type 2 Codable 信封；流终结即连接断开
        readTask = Task { [weak self, conn] in
            var endedNormally = false
            do {
                for try await message in conn.messages {
                    switch message.metadata.type {
                    case TLVMessageType.control:
                        DispatchQueue.main.async { self?.onControl?(message.content) }
                    case TLVMessageType.envelope:
                        // 解码失败即忽略（向后兼容：新版 Mac 新增的 case 不应使旧手机断连）
                        if let msg = try? JSONDecoder().decode(
                            AimMessage.self, from: message.content) {
                            DispatchQueue.main.async { self?.onMessage?(msg) }
                        }
                    default:
                        break   // 未知 type 忽略（向后兼容：新版 Mac 新增的 type 不应使旧手机断连）
                    }
                }
                endedNormally = true
            } catch {
                // 断开/取消时 messages 抛错终结，走统一断开路径
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == gen, self.isConnected else { return }
                self.isConnected = false
                self.onEvent?(.disconnected(text: endedNormally ? "对端已关闭" : "连接已断开"))
            }
        }

        // NOTE: 看门狗——本地网络授权弹窗期连接会永久卡死（protocol.md §4），
        // establishmentReport 与 5s 超时竞争，超时即取消重来
        watchdogTask = Task { [weak self, conn] in
            let established = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                        _ = try? await conn.establishmentReport()
                        return true
                    }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        return false
                    }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            guard !established, !Task.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == gen, !self.isConnected else { return }
                self.retryOrFail(endpoint: endpoint, label: label, timeout: true)
            }
        }
    }

    private func handleState(_ state: NetworkChannel<TLV>.State, gen: Int,
                             endpoint: NWEndpoint, label: String) {
        guard generation == gen else { return }   // 旧连接的迟到状态不影响新连接
        switch state {
        case .ready:
            retryCount = 0
            isConnected = true
            onEvent?(.ready(label: label))
        case .waiting:
            onEvent?(.waiting)
        case .failed(let e):
            if isConnected {
                isConnected = false
                onEvent?(.disconnected(text: e.localizedDescription))
            } else {
                // 失败快速重试，不傻等看门狗
                retryOrFail(endpoint: endpoint, label: label, timeout: false,
                            error: e)
            }
        default:
            break
        }
    }

    /// 失败/超时统一重试入口：最多 6 次，耗尽报终态失败（文案同旧路径）
    private func retryOrFail(endpoint: NWEndpoint, label: String, timeout: Bool,
                             error: Error? = nil) {
        retryCount += 1
        if retryCount <= 6 {
            if timeout {
                onEvent?(.retrying(text: "连接超时，第 \(retryCount) 次重试…"))
                startConnection(endpoint: endpoint, label: label)
            } else {
                onEvent?(.retrying(text: "连接失败，1 秒后第 \(retryCount) 次重试…"))
                let gen = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.generation == gen, !self.isConnected else { return }
                    self.startConnection(endpoint: endpoint, label: label)
                }
            }
        } else {
            onEvent?(.failed(text: "多次连接失败：检查 Mac 服务是否在运行，以及 设置 > AimPhone 的本地网络权限"))
        }
    }

    /// 取消当前连接（保留状态给调用方复位）；readTask 取消即连接取消
    private func teardownConnection() {
        watchdogTask?.cancel()
        watchdogTask = nil
        readTask?.cancel()
        readTask = nil
        connection = nil
        isConnected = false
    }

    /// 静默断开（不发 mouseUp/disconnect 兜底帧）：fast 时敏通道专用（ADR-017），
    /// 断开兜底语义只属于主连接
    func close() {
        generation += 1   // 断开后的迟到回调全部失效
        teardownConnection()
    }

    /// 主动断开：先补发 mouseUp all + disconnect 兜底帧（protocol.md §7/§8，ADR-008），
    /// 以 lastMessage 收尾保证通知帧先于 FIN 到达（等价旧路径 finalMessage 语义）。
    /// NOTE: readTask 取消即连接取消——须等兜底帧发完再取消，故拆出独立收尾 Task
    func disconnectGracefully() {
        generation += 1   // 断开后的迟到回调全部失效
        guard let conn = connection, isConnected else {
            teardownConnection()
            return
        }
        isConnected = false
        watchdogTask?.cancel()
        watchdogTask = nil
        connection = nil
        if let json = try? JSONSerialization.data(
            withJSONObject: ["type": "mouseUp", "button": "all"]) {
            conn.sendIdempotent(json, type: TLVMessageType.control)
        }
        let pendingReadTask = readTask
        readTask = nil
        Task { [conn] in
            if let json = try? JSONSerialization.data(withJSONObject: ["type": "disconnect"]) {
                try? await conn.send(json, type: TLVMessageType.control, lastMessage: true)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)   // 给 FIN 留出发送窗口
            pendingReadTask?.cancel()
        }
    }

    // MARK: 发送（挂起即背压；高频路径用 sendIdempotent，与旧 .idempotent 语义一致）

    func send(jpeg: Data) {
        guard let conn = connection, isConnected else { return }
        conn.sendIdempotent(jpeg, type: TLVMessageType.video)
    }

    func sendControl(_ obj: [String: Any]) {
        guard let conn = connection, isConnected,
              let json = try? JSONSerialization.data(withJSONObject: obj) else { return }
        conn.sendIdempotent(json, type: TLVMessageType.control)
    }

    // MARK: 采集上传（并入主连接 type 10/11，protocol.md §11；不再有第二条 TCP）

    /// 上传一段采集记录：session(type 10) → 每帧 type 11 复合 payload → end(type 10)。
    /// 串行 `try await send` 逐条背压（等价旧路径 contentProcessed 链），
    /// 上传完成后清理临时目录；状态文案经 onDone 回主线程
    func uploadCapture(dir: URL, total: Int, peakRotRate: Double,
                       onDone: @escaping (String) -> Void) {
        guard let conn = connection, isConnected else {
            DispatchQueue.main.async { onDone("采集上传失败：未连接") }
            return
        }
        let gen = generation
        Task { [weak self] in
            do {
                var uts = utsname()
                uname(&uts)
                let model = withUnsafeBytes(of: &uts.machine) { ptr in
                    String(cString: ptr.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                #if canImport(UIKit)
                let osVersion = UIDevice.current.systemVersion
                #else
                // macOS 编译仅用于 tools/ 传输测试台（TLVTransport 的线上目标是 iOS）
                let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
                #endif
                let session: [String: Any] = ["kind": "session", "device": model,
                                              "os": osVersion]
                try await conn.send(JSONSerialization.data(withJSONObject: session),
                                    type: TLVMessageType.captureMeta)
                let metaRaw = try Data(contentsOf: dir.appendingPathComponent("meta.jsonl"))
                guard let metaText = String(data: metaRaw, encoding: .utf8) else {
                    throw NSError(domain: "AimPhone", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "meta.jsonl 读取失败"])
                }
                let lines = metaText.split(separator: "\n").map(String.init)
                for (i, line) in lines.enumerated() {
                    // 单帧缺失不阻塞整体上传
                    guard let json = line.data(using: .utf8),
                          let png = try? Data(contentsOf: dir.appendingPathComponent(
                            String(format: "frames/%04d.png", i + 1))) else { continue }
                    var payload = Data()
                    var jl = UInt32(json.count).bigEndian
                    payload.append(withUnsafeBytes(of: &jl) { Data($0) })
                    payload.append(json)
                    payload.append(png)
                    try await conn.send(payload, type: TLVMessageType.captureFrame)
                    // P1 Step 1 pacing：yield 给视频帧/控制消息插队窗口；按字节折算
                    // 限速睡眠，把回传压到 captureUploadRate（只在此循环内生效）
                    await Task.yield()
                    try? await Task.sleep(nanoseconds: UInt64(
                        Double(payload.count) / captureUploadRate * 1e9))
                }
                let end: [String: Any] = ["kind": "end", "frames": total,
                                          "peakRotRate": peakRotRate]
                try await conn.send(JSONSerialization.data(withJSONObject: end),
                                    type: TLVMessageType.captureMeta)
                try? FileManager.default.removeItem(at: dir)   // 35–75MB/段，不留垃圾
                DispatchQueue.main.async { onDone("采集已上传（\(total) 帧）") }
            } catch {
                // NOTE: 连接在上传中途换代（断开/重连）时静默失败，旧路径同语义
                DispatchQueue.main.async { [weak self] in
                    guard self?.generation == gen else { return }
                    onDone("采集上传失败: \(error.localizedDescription)")
                }
            }
        }
    }
}
