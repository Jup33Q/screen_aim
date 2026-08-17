//
//  main.swift
//  tools/tlv-loopback — TLV 消息流本机回环验证：消息边界 / type 路由 / 复合 payload
//
//  关键约束：macOS 26+；直接编 FrameServerV2 真实代码路径（非 mock），
//  覆盖 protocol.md §11 的 type 0/1/10/11 与采集落盘目录结构
//
//  用法：tools/tlv-loopback/run.sh（编译并运行，退出码 0 = 全过）
//

import Foundation
import Network
import ScreenAimCore   // TLVMessageType（测试台里编成同名模块，见 run.sh）

// 与 ScreenAim 主 target 共享实现（run.sh 把两份源码一起编译）
// FrameServerV2 / TLVMessageType / CaptureIngestor 来自 Sources/ScreenAim/FrameServerV2.swift

let port: UInt16 = 19317
let jpegFake = Data((0..<100_000).map { UInt8($0 % 251) })   // 伪 JPEG 帧（100KB）
let controlObj: [String: Any] = ["type": "localAim", "markers": 6, "x": 864.0, "y": 558.5]
let sessionObj: [String: Any] = ["kind": "session", "device": "iPhone16,2", "os": "26.6"]
let frameObj: [String: Any] = ["kind": "frame", "seq": 1, "pts": 0.5]
let pngFake = Data((0..<50_000).map { UInt8(($0 * 7) % 253) })
let endObj: [String: Any] = ["kind": "end", "frames": 1, "peakRotRate": 0.3]

final class Checker {
    var videoOK = false
    var controlOK = false
    var captureDone = false
    var failures: [String] = []
    func fail(_ s: String) { failures.append(s); print("[loopback] FAIL: \(s)") }
}

let checker = Checker()
let server = FrameServerV2(port: port) { data in
    if data == jpegFake { checker.videoOK = true }
    else { checker.fail("type 0 视频帧内容不一致（\(data.count) 字节）") }
}
server.handshakePayload = {
    try? JSONSerialization.data(withJSONObject: ["type": "calib", "screenW": 1728.0])
}
server.onControl = { obj in
    if (obj["type"] as? String) == "localAim", (obj["markers"] as? Int) == 6 {
        checker.controlOK = true
    } else { checker.fail("type 1 控制消息内容不符: \(obj)") }
}
server.sessionInfo = { ["label": "loopback", "screenW": 1728.0, "screenH": 1117.0] }
server.onCaptureDone = { dir in
    // 落盘校验：frames/0001.png 与 meta.jsonl / session.json 三件套齐全且字节一致
    let png = try? Data(contentsOf: dir.appendingPathComponent("frames/0001.png"))
    let meta = try? String(contentsOf: dir.appendingPathComponent("meta.jsonl"), encoding: .utf8)
    let session = try? Data(contentsOf: dir.appendingPathComponent("session.json"))
    if png != pngFake { checker.fail("采集 PNG 落盘字节不一致") }
    if meta?.contains("\"seq\":1") != true { checker.fail("meta.jsonl 缺 seq=1 行") }
    if session == nil { checker.fail("session.json 缺失") }
    if checker.failures.isEmpty { print("[loopback] 采集落盘 OK: \(dir.path)") }
    try? FileManager.default.removeItem(at: dir)   // 验证完即清理
    checker.captureDone = true
}
try server.start()

// 客户端：先连上（收握手 calib），再依次发 type 0/1/10/11/10(end)
Task {
    do {
        let conn = NetworkConnection(to: .hostPort(host: "127.0.0.1",
                                                   port: .init(integerLiteral: port))) {
            TLV { TCP() }
        }
        // 接收循环：验证握手 calib 到达（type 1，Mac→iPhone 方向）
        let reader = Task {
            var gotHandshake = false
            for try await message in conn.messages {
                if message.metadata.type == TLVMessageType.control,
                   let obj = try? JSONSerialization.jsonObject(with: message.content) as? [String: Any],
                   obj["type"] as? String == "calib" {
                    gotHandshake = true
                    print("[loopback] 握手 calib 已到达")
                }
            }
            if !gotHandshake { checker.fail("握手 calib 未到达") }
        }
        _ = try await conn.establishmentReport()   // 挂起直到连接建立（首包即连接）

        try await conn.send(jpegFake, type: TLVMessageType.video)
        try await conn.send(JSONSerialization.data(withJSONObject: controlObj),
                            type: TLVMessageType.control)
        try await conn.send(JSONSerialization.data(withJSONObject: sessionObj),
                            type: TLVMessageType.captureMeta)
        // type 11 复合 payload：[4B 大端 jsonLen][json][PNG]
        let frameJSON = try JSONSerialization.data(withJSONObject: frameObj)
        var composite = Data()
        var jl = UInt32(frameJSON.count).bigEndian
        composite.append(withUnsafeBytes(of: &jl) { Data($0) })
        composite.append(frameJSON)
        composite.append(pngFake)
        try await conn.send(composite, type: TLVMessageType.captureFrame)
        try await conn.send(JSONSerialization.data(withJSONObject: endObj),
                            type: TLVMessageType.captureMeta, lastMessage: true)

        // 等服务端处理完（采集收尾含主线程派发）
        try await Task.sleep(nanoseconds: 1_000_000_000)
        reader.cancel()   // 新 NetworkConnection 无 cancel()：Task 取消即连接取消，离开作用域回收
    } catch {
        checker.fail("客户端异常: \(error.localizedDescription)")
    }

    var ok = true
    for (name, flag) in [("type 0 视频帧", checker.videoOK),
                         ("type 1 控制消息", checker.controlOK),
                         ("type 10/11 采集落盘", checker.captureDone)] {
        print("[loopback] \(name): \(flag ? "OK" : "FAIL")")
        if !flag { ok = false }
    }
    print(ok && checker.failures.isEmpty ? "[loopback] 全部通过" : "[loopback] 存在失败项")
    exit(ok && checker.failures.isEmpty ? 0 : 1)
}

RunLoop.main.run()
