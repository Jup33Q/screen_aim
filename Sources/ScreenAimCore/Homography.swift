//
//  Homography.swift
//  ScreenAimCore — 纯 Swift 四点单应矩阵（DLT + 高斯消元），iOS/macOS 双端可用
//
//  与 Mac 端 OpenCV getPerspectiveTransform 同语义：4 组对应点求解 3×3 单应，
//  map 把点从 src 平面映射到 dst 平面（结果单位 = dst 单位，自动吸收缩放）。
//

import Foundation
import CoreGraphics

/// 3×3 单应矩阵（行优先 9 元素，h[8] 归一为 1）
public struct Homography {
    public var h: [Double]   // 9 elements, row-major

    /// 四点 DLT 求解。src/dst 必须恰好 4 个点且不共线；求解失败返回 nil
    public init?(src: [CGPoint], dst: [CGPoint]) {
        guard src.count == 4, dst.count == 4 else { return nil }

        // 每组对应点 (x,y)->(u,v) 贡献两行：
        //   [x y 1 0 0 0 -u·x -u·y] = u
        //   [0 0 0 x y 1 -v·x -v·y] = v
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)  // 8 列系数 + 1 列常数
        for i in 0..<4 {
            let x = src[i].x, y = src[i].y
            let u = dst[i].x, v = dst[i].y
            a[2 * i]     = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }

        // 高斯消元（部分主元）
        for col in 0..<8 {
            var pivot = col
            for r in (col + 1)..<8 where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            if abs(a[pivot][col]) < 1e-12 { return nil }   // 奇异（点共线/退化）
            if pivot != col { a.swapAt(pivot, col) }
            let d = a[col][col]
            for c in col...8 { a[col][c] /= d }
            for r in 0..<8 where r != col {
                let f = a[r][col]
                if f == 0 { continue }
                for c in col...8 { a[r][c] -= f * a[col][c] }
            }
        }
        h = [a[0][8], a[1][8], a[2][8],
             a[3][8], a[4][8], a[5][8],
             a[6][8], a[7][8], 1]
    }

    /// 点映射：p → H·p（透视除法）
    public func map(_ p: CGPoint) -> CGPoint {
        let x = p.x, y = p.y
        let w = h[6] * x + h[7] * y + h[8]
        guard abs(w) > 1e-12 else { return p }
        return CGPoint(x: (h[0] * x + h[1] * y + h[2]) / w,
                       y: (h[3] * x + h[4] * y + h[5]) / w)
    }
}
