//
//  main.swift
//  tools/tlv-upload-test — 采集回传 TLV 路径端到端测试台（TLVTransport 真实代码）
//
//  关键约束：macOS 26+；FrameServerV2（服务端）与 TLVTransport（客户端，iOS 线上代码
//  经 #if canImport(UIKit) 兼容编译）在本机回环，验证 protocol.md §11 type 10/11 上传与落盘
//
//  用法：tools/tlv-upload-test/run.sh（编译并运行，退出码 0 = 全过）
//

import Foundation
import Network
import ScreenAimCore   // TLVMessageType（测试台里编成同名模块，见 run.sh）

// FrameServerV2/TLVMessageType 来自 Sources/，TLVTransport 来自 ios/AimPhone/（run.sh 一起编译）

let port: UInt16 = 19319
let frames = 3

// 造一段合成采集（结构同 CaptureRecorder 输出：frames/NNNN.png + meta.jsonl）
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("capture_tlvtest", isDirectory: true)
try? FileManager.default.removeItem(at: tmp)
try FileManager.default.createDirectory(at: tmp.appendingPathComponent("frames"),
                                        withIntermediateDirectories: true)
var pngs: [Data] = []
var metaLines: [String] = []
for i in 1...frames {
    let png = Data((0..<20_000).map { UInt8(($0 * i) % 251) })
    pngs.append(png)
    try png.write(to: tmp.appendingPathComponent(String(format: "frames/%04d.png", i)))
    let meta = "{\"kind\":\"frame\",\"seq\":\(i),\"pts\":\(Double(i) * 0.2)}"
    metaLines.append(meta)
}
try metaLines.joined(separator: "\n").write(to: tmp.appendingPathComponent("meta.jsonl"),
                                            atomically: true, encoding: .utf8)

var failures: [String] = []
func fail(_ s: String) { failures.append(s); print("[upload-test] FAIL: \(s)") }

let server = FrameServerV2(port: port, onFrame: { _ in })
var done = false
server.onCaptureDone = { dir in
    defer { done = true }
    for (i, png) in pngs.enumerated() {
        let landed = try? Data(contentsOf: dir.appendingPathComponent(
            String(format: "frames/%04d.png", i + 1)))
        if landed != png { fail("帧 \(i + 1) PNG 字节不一致") }
    }
    let meta = try? String(contentsOf: dir.appendingPathComponent("meta.jsonl"), encoding: .utf8)
    // 落盘时 JSON 重序列化（与旧 CaptureServer 同行为），按 seq 校验而非字节比对
    let landedSeqs = (meta ?? "").split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["seq"] as? Int
    }
    if landedSeqs != Array(1...frames) { fail("meta.jsonl seq 序列不符: \(landedSeqs)") }
    guard let sessionData = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
          let session = try? JSONSerialization.jsonObject(with: sessionData) as? [String: Any]
    else { fail("session.json 缺失/不可解析"); return }
    if (session["frames"] as? Int) != frames { fail("session.json frames 数不符") }
    if (session["device"] as? String) == nil { fail("session.json 缺 device 合并字段") }
    try? FileManager.default.removeItem(at: dir)
    if failures.isEmpty { print("[upload-test] 服务端落盘校验 OK") }
}
try server.start()

let transport = TLVTransport()
transport.onEvent = { e in
    if case .ready = e {
        print("[upload-test] TLV 已连接，开始上传")
        transport.uploadCapture(dir: tmp, total: frames, peakRotRate: 1.5) { text in
            print("[upload-test] \(text)")
            // 给服务端收尾（主线程派发）留 1s
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if !done { fail("onCaptureDone 未触发") }
                print(failures.isEmpty ? "[upload-test] 全部通过" : "[upload-test] 存在失败项")
                exit(failures.isEmpty ? 0 : 1)
            }
        }
    }
}
transport.connect(host: "127.0.0.1", port: port)

// 总超时 20s 兜底
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    print("[upload-test] FAIL: 总超时")
    exit(1)
}
RunLoop.main.run()
