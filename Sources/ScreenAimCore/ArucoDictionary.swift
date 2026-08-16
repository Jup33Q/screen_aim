//
//  ArucoDictionary.swift
//  ScreenAimCore — DICT_4X4_50 字典位图（本项目只用 id 0-3 作屏幕四角定位码）
//
//  位图约定：行优先（左上→右下）打包成 UInt16，MSB 在前；1 = 白色格
//  （与 OpenCV generateImageMarker 的渲染约定一致）。
//  数值由 markers/marker_*.png（OpenCV 5.0 生成，400px，borderBits=1）逐格解码而来，
//  与 Mac 端 OpenCVBridge 使用的 DICT_4X4_50 是同一套标记。
//

import Foundation

public enum ArucoDictionary {
    /// 位图 → 标记 id
    public static let bits: [UInt16: Int] = [
        0xB532: 0,
        0x0F9A: 1,
        0x332D: 2,
        0x9946: 3,
    ]

    /// 4×4 位图顺时针旋转 90°（旋转后 (r,c) → (c, 3-r)）
    public static func rotateCW(_ v: UInt16) -> UInt16 {
        var out: UInt16 = 0
        for r in 0..<4 {
            for c in 0..<4 {
                let bit = (v >> UInt16(15 - (r * 4 + c))) & 1
                let nr = c, nc = 3 - r
                out |= bit << UInt16(15 - (nr * 4 + nc))
            }
        }
        return out
    }

    /// 对 4 个旋转方向逐一查字典；命中返回 (id, 顺时针旋转次数)，未命中返回 nil。
    /// 先精确匹配，再放宽到汉明距 1（DICT_4X4_50 码间最小汉明距为 4，纠 1 bit 安全）——
    /// 模糊帧上单格采样误判 1 bit 是常态，OpenCV 端同样有 maxCorrectionBits 纠错
    public static func lookup(_ v: UInt16) -> (id: Int, rotation: Int)? {
        var x = v
        for rot in 0..<4 {
            if let id = bits[x] { return (id, rot) }
            x = rotateCW(x)
        }
        x = v
        for rot in 0..<4 {
            for bit in 0..<16 {
                if let id = bits[x ^ (1 << UInt16(bit))] { return (id, rot) }
            }
            x = rotateCW(x)
        }
        return nil
    }
}
