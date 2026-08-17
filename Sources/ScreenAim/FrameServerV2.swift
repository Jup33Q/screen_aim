//
//  FrameServerV2.swift
//  ScreenAim（Mac 端）— TLV 消息流帧服务：单连接承载视频帧 / 控制消息 / 采集回传
//
//  关键约束：Network.framework 26+ 结构化并发 API（NetworkListener + 内置 TLV framer），
//  线上格式 [type: UInt32][length: UInt32][value]（8 字节头，框架拼包/拆包，见 docs/protocol.md §11）。
//  回调在连接子任务上下文触发（非主线程，与旧版 conn 队列语义一致），UI 操作需自行派主线程。
//  P3 起为唯一传输服务：复用 9100 端口与 _aimphone._tcp 服务名（ADR-011 ①④，旧链路已拆除）。
//

import Foundation
import Network
import ScreenAimCore

// NOTE: TLVMessageType 在 ScreenAimCore（双端共享的线上常量，docs/protocol.md §11）

// MARK: - 采集落盘（protocol.md §11）
/// 采集会话落盘器（type 10/11 路径，P3 起唯一存续；与已拆除的旧 CaptureServer 同源逻辑）。
/// 线程约束：实例由单个连接子任务独占使用，无跨连接共享；onCaptureDone 派主线程。
final class CaptureIngestor {
    /// 当前采集会话的 Mac 侧元信息（label/标记参数/映射表，写 session.json 用）
    var sessionInfo: (() -> [String: Any])?
    /// 一次上传完成（或中途断连兜底收尾）回调，参数为落盘目录；主线程派发
    var onCaptureDone: ((URL) -> Void)?

    private var dir: URL?
    private var metaHandle: FileHandle?
    private var frames = 0
    private var bytes: Int64 = 0
    private var phoneSession: [String: Any] = [:]
    private var finished = false

    /// 处理一条采集记录。`bin` 为帧 PNG；session/end 记录传空
    func process(_ obj: [String: Any], bin: Data) {
        switch obj["kind"] as? String {
        case "session":
            phoneSession = obj
            let info = sessionInfo?() ?? [:]
            let rawLabel = (info["label"] as? String ?? "")
                .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            let label = rawLabel.isEmpty ? "session" : rawLabel
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("scenes/capture_\(label)_\(stamp)", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir.appendingPathComponent("frames", isDirectory: true),
                withIntermediateDirectories: true)
            let metaURL = dir.appendingPathComponent("meta.jsonl")
            FileManager.default.createFile(atPath: metaURL.path, contents: nil)
            metaHandle = FileHandle(forWritingAtPath: metaURL.path)
            self.dir = dir
        case "frame":
            guard let dir, let seq = obj["seq"] as? Int else { return }
            try? bin.write(to: dir.appendingPathComponent(
                String(format: "frames/%04d.png", seq)))
            metaHandle?.write(jsonLine(obj))
            frames += 1
            bytes += Int64(bin.count)
        case "end":
            finish()
        default:
            break
        }
    }

    private func jsonLine(_ obj: [String: Any]) -> Data {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return Data() }
        return d + Data([0x0A])
    }

    /// 收尾（收到 end 记录或连接断开兜底）：合并双端元信息写 session.json，打印摘要，通知 UI
    func finish() {
        guard !finished, dir != nil else { return }
        finished = true
        metaHandle?.closeFile()
        guard let dir else { return }
        var session = sessionInfo?() ?? [:]
        session["device"] = phoneSession["device"] ?? "unknown"
        session["os"] = phoneSession["os"] ?? "unknown"
        session["frames"] = frames
        session["bytes"] = bytes
        if let d = try? JSONSerialization.data(withJSONObject: session,
                                               options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("session.json"))
        }
        print(String(format: "采集落盘: %@（%d 帧，%.1fMB）",
                     dir.path, frames, Double(bytes) / 1e6))
        DispatchQueue.main.async { self.onCaptureDone?(dir) }
    }
}

// MARK: - TLV 帧服务
/// TLV 单连接帧服务（9100 端口，Bonjour `_aimphone._tcp`）。
/// 连接建立即下发标定映射表（type 1），随后 `messages` 异步序列按 type 分发：
/// 0 视频帧 → onFrame；1 控制 JSON → onControl；10/11 采集记录 → CaptureIngestor。
/// `try await send` 的挂起即背压（框架托管流控），15fps 视频天然节流。
final class FrameServerV2 {
    let port: UInt16
    let onFrame: (Data) -> Void
    var onConnect: (() -> Void)?      // 手机连上时回调（主线程派发，用于隐藏配对二维码）
    /// 新连接建立后立刻下发一次的控制消息（标定映射表，protocol.md §6/§11）；nil 则不发
    var handshakePayload: (() -> Data?)?
    /// 手机端控制消息回调（type 1 JSON），参数为 JSON 对象；连接子任务上下文
    var onControl: (([String: Any]) -> Void)?
    /// 连接断开回调（主动/被动都会触发，主线程派发；§8 鼠标按键卡死兜底用）
    var onDisconnect: (() -> Void)?
    /// 监听器失败回调（主线程）。NOTE: 同旧 FrameServer——绑定失败是异步上报的，
    /// 不处理会留下永远配不对的"僵尸二维码"
    var onListenerFailed: ((Error) -> Void)?
    /// 采集回传（并入本连接，type 10/11）：回调面与旧 CaptureServer 对齐
    var sessionInfo: (() -> [String: Any])?
    var onCaptureDone: ((URL) -> Void)?

    /// 存活连接表（sendControl 广播用）。NSLock 保护：注册/注销在连接子任务，
    /// 广播在主线程（UI 事件路径）
    private var activeConns: [NetworkConnection<TLV>] = []
    private let connsLock = NSLock()
    private var listenerTask: Task<Void, Never>?

    init(port: UInt16, onFrame: @escaping (Data) -> Void) {
        self.port = port
        self.onFrame = onFrame
    }

    func start() throws {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "ScreenAim", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "非法端口 \(port)"])
        }
        let listener = try NetworkListener(
            // P3 收敛后复用旧服务名与端口（_aimphone._tcp / 9100），线上只有 TLV 一种协议
            for: .bonjour(name: "AimPhone-Mac", type: "_aimphone._tcp"),
            using: .parameters {
                // NOTE: noDelay 必须显式开——Nagle 攒批会把 15fps 的小控制消息积成
                // ~200ms 一坨（真机实测 localAim 批量 46Hz 突发、白点阶梯滞后）；
                // TCP() 默认 noDelay=false，与旧 NWConnection .tcp 的默认不同
                TLV { TCP().noDelay(true) }
            }
                .localPort(p)
                .serviceClass(.interactiveVideo))
        listener.onStateUpdate { [weak self] _, state in
            print("TLV 帧服务状态: \(state)")
            if case .failed(let e) = state {
                DispatchQueue.main.async { self?.onListenerFailed?(e) }
            }
        }
        listenerTask = Task { [weak self] in
            do {
                try await listener.run { connection in
                    await self?.handleConnection(connection)
                }
            } catch {
                // run 返回即监听终结（取消/失败）；失败路径已由 onStateUpdate 覆盖
                if !Task.isCancelled {
                    print("TLV 帧服务监听结束: \(error.localizedDescription)")
                }
            }
        }
        print("TLV 帧服务已启动，端口 \(port)（_aimphone._tcp），等待手机连接…")
    }

    /// 向所有存活连接广播控制消息（Mac → iPhone，type 1，protocol.md §6/§11）
    func sendControl(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        connsLock.lock()
        let conns = activeConns
        connsLock.unlock()
        for conn in conns {
            // sendIdempotent：与旧路径 .idempotent 完成语义一致（不保证送达的控制广播可丢弃）
            conn.sendIdempotent(data, type: TLVMessageType.control)
        }
    }

    // MARK: 连接生命周期

    private func register(_ conn: NetworkConnection<TLV>) {
        connsLock.lock()
        activeConns.append(conn)
        connsLock.unlock()
    }

    private func unregister(_ conn: NetworkConnection<TLV>) {
        connsLock.lock()
        activeConns.removeAll { $0 == conn }
        connsLock.unlock()
    }

    /// 单连接服务循环（listener.run 的子任务上下文；Task 取消即连接取消）
    private func handleConnection(_ conn: NetworkConnection<TLV>) async {
        print("手机已连接（TLV）: \(conn.remoteEndpoint?.debugDescription ?? "?")")
        register(conn)
        DispatchQueue.main.async { self.onConnect?() }
        // 每连接独立采集落盘器：录制→停止→回传时序与视频流共用连接（ADR-011 ④）
        let ingestor = CaptureIngestor()
        ingestor.sessionInfo = sessionInfo
        ingestor.onCaptureDone = onCaptureDone
        defer {
            unregister(conn)
            ingestor.finish()   // 中途断连按已收帧数兜底收尾
            DispatchQueue.main.async { self.onDisconnect?() }
        }
        // 控制信道：连接建立即下发标定映射表（type 1）
        if let data = handshakePayload?() {
            try? await conn.send(data, type: TLVMessageType.control)
            print("标定映射表已下发（TLV，\(data.count) 字节）")
        }
        do {
            for try await message in conn.messages {
                dispatch(message.content, type: message.metadata.type, ingestor: ingestor)
            }
        } catch {
            // 断开/取消时 messages 抛错终结，属正常收尾路径
        }
    }

    /// TLV type 路由：未知 type 忽略（向后兼容：新版手机新增的 type 不应使旧 Mac 断连）
    private func dispatch(_ data: Data, type: Int, ingestor: CaptureIngestor) {
        switch type {
        case TLVMessageType.video:
            onFrame(data)
        case TLVMessageType.control:
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                onControl?(obj)
            }
        case TLVMessageType.captureMeta:
            // session/end 记录（纯 JSON，无二进制体）
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                ingestor.process(obj, bin: Data())
            }
        case TLVMessageType.captureFrame:
            // 复合 payload：[4B 大端 jsonLen][json][PNG]（协议 §11）
            guard data.count >= 4 else { return }
            let jsonLen = Int(data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard jsonLen > 0, jsonLen < 1_000_000, data.count >= 4 + jsonLen,
                  let obj = try? JSONSerialization.jsonObject(
                    with: data.subdata(in: 4..<(4 + jsonLen))) as? [String: Any]
            else { return }
            ingestor.process(obj, bin: data.subdata(in: (4 + jsonLen)..<data.count))
        default:
            break
        }
    }
}
