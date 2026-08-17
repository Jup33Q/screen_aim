//
//  Homography.swift
//  ScreenAimCore — 纯 Swift 单应矩阵：四点 DLT（高斯消元）+ ≥4 点 RANSAC/最小二乘；
//  附 AffineTransform（恰好 3 点闭式解，WP1.1 定位兜底）。
//  iOS/macOS 双端可用（最小二乘用系统框架 Accelerate 的 dsyev_，零第三方依赖）
//
//  与 Mac 端 OpenCV getPerspectiveTransform / findHomography 同语义：
//  map 把点从 src 平面映射到 dst 平面（结果单位 = dst 单位，自动吸收缩放）。
//

import Foundation
import CoreGraphics
import Accelerate

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

    /// RANSAC 单应：≥4 点鲁棒求解（冗余 8 标记模式，见 ADR-007）。
    /// 迭代 maxIter 次随机抽 4 点用四点 DLT 求解，重投影误差 < thresholdPx 记内点；
    /// 最优内点集 ≥4 才成功，最终在内点集上重解（>4 点走最小二乘精化）。
    /// - Parameters:
    ///   - thresholdPx: 内点判定阈值（dst 坐标单位，屏幕 pt 下 2.0 足够剔除掉检错位点）
    public init?(ransacSrc src: [CGPoint], dst: [CGPoint],
                 thresholdPx: Double = 2.0, maxIter: Int = 50) {
        guard src.count >= 4, dst.count == src.count else { return nil }
        // 恰好 4 点无冗余可剔，直接精确解（失败则向上传播 nil）
        if src.count == 4 { self.init(src: src, dst: dst); return }

        var rng = SystemRandomNumberGenerator()
        var bestInliers: [Int] = []
        for _ in 0..<maxIter {
            var sample: [Int] = []
            while sample.count < 4 {
                let i = Int.random(in: 0..<src.count, using: &rng)
                if !sample.contains(i) { sample.append(i) }
            }
            guard let h4 = Homography(src: sample.map { src[$0] },
                                      dst: sample.map { dst[$0] }) else { continue }
            var inliers: [Int] = []
            for i in 0..<src.count {
                let p = h4.map(src[i])
                if hypot(p.x - dst[i].x, p.y - dst[i].y) < thresholdPx { inliers.append(i) }
            }
            if inliers.count > bestInliers.count { bestInliers = inliers }
        }
        guard bestInliers.count >= 4 else { return nil }
        let isrc = bestInliers.map { src[$0] }, idst = bestInliers.map { dst[$0] }
        if bestInliers.count == 4 { self.init(src: isrc, dst: idst); return }
        guard let refined = Homography(leastSquaresSrc: isrc, dst: idst) else { return nil }
        self = refined
    }

    /// 最小二乘单应（>4 点，Ah=0 的最小奇异向量解）：构造 2N×9 的 A，
    /// 对 AᵀA（9×9 对称阵）用 Accelerate dsyev_ 取最小特征值对应特征向量。
    /// NOTE: 坐标量级 ≤ 几千（像素/点），Double 动态范围足够，不做 Hartley 归一化
    private init?(leastSquaresSrc src: [CGPoint], dst: [CGPoint]) {
        // 直接累加 AᵀA（列主序存放，供 LAPACK）；每点贡献两行：
        //   [x y 1 0 0 0 -u·x -u·y -u] 与 [0 0 0 x y 1 -v·x -v·y -v]（第 9 列对应 h[8]）
        var ata = [Double](repeating: 0, count: 81)
        for i in 0..<src.count {
            let x = src[i].x, y = src[i].y, u = dst[i].x, v = dst[i].y
            let rows = [[x, y, 1, 0, 0, 0, -u * x, -u * y, -u],
                        [0, 0, 0, x, y, 1, -v * x, -v * y, -v]]
            for r in rows {
                for c in 0..<9 {
                    guard r[c] != 0 else { continue }
                    for d in 0..<9 { ata[d * 9 + c] += r[c] * r[d] }
                }
            }
        }
        var n: __CLPK_integer = 9, lda: __CLPK_integer = 9, info: __CLPK_integer = 0
        var eigen = [Double](repeating: 0, count: 9)
        var jobz = CChar(86)   // 'V'：算特征向量
        var uplo = CChar(85)   // 'U'：上三角
        // workspace 查询后正式求解
        var workQuery = 0.0
        var lwork: __CLPK_integer = -1
        dsyev_(&jobz, &uplo, &n, &ata, &lda, &eigen, &workQuery, &lwork, &info)
        lwork = __CLPK_integer(workQuery)
        var work = [Double](repeating: 0, count: Int(lwork))
        dsyev_(&jobz, &uplo, &n, &ata, &lda, &eigen, &work, &lwork, &info)
        guard info == 0 else { return nil }
        // dsyev_ 特征值升序返回，最小特征向量 = 输出矩阵第 0 列（列主序 ata[0..<9]）
        let h9 = (0..<9).map { ata[$0] }
        guard abs(h9[8]) > 1e-12 else { return nil }
        h = h9.map { $0 / h9[8] }
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

/// 二维仿射变换（6 参数）：恰好 3 对对应点的闭式精确解（WP1.1 定位兜底，ADR-013）。
///
/// 屏幕是平面，三点簇内仿射与单应的误差仅 pt 级；但仿射不能外推透视，
/// 远离三角形后误差发散——调用方必须用凸包护栏限制使用范围
/// （`ScreenLocalizer.affineGuardFactor`），护栏外的输出宁可没有。
public struct AffineTransform {
    /// [a b c d e f]：u = a·x + b·y + c，v = d·x + e·y + f
    public var m: [Double]

    /// 三点闭式解（Cramer 法则，无需 Accelerate）。src/dst 必须恰好 3 点；
    /// 三点共线/退化返回 nil
    public init?(src: [CGPoint], dst: [CGPoint]) {
        guard src.count == 3, dst.count == 3 else { return nil }
        let x0 = src[0].x, y0 = src[0].y, x1 = src[1].x, y1 = src[1].y, x2 = src[2].x, y2 = src[2].y
        // 系数矩阵 [x y 1] 三行的行列式；≈0 即三点共线（面元退化，无解）
        let den = x0 * (y1 - y2) + x1 * (y2 - y0) + x2 * (y0 - y1)
        guard abs(den) > 1e-12 else { return nil }
        // u 行与 v 行同系数矩阵，仅常数列不同，同一组 Cramer 公式套两次
        func row(_ u0: Double, _ u1: Double, _ u2: Double) -> (Double, Double, Double) {
            let a = (u0 * (y1 - y2) + u1 * (y2 - y0) + u2 * (y0 - y1)) / den
            let b = (x0 * (u1 - u2) + x1 * (u2 - u0) + x2 * (u0 - u1)) / den
            let c = (x0 * (y1 * u2 - y2 * u1) + x1 * (y2 * u0 - y0 * u2) + x2 * (y0 * u1 - y1 * u0)) / den
            return (a, b, c)
        }
        let (a, b, c) = row(dst[0].x, dst[1].x, dst[2].x)
        let (d, e, f) = row(dst[0].y, dst[1].y, dst[2].y)
        m = [a, b, c, d, e, f]
    }

    /// 点映射：p → M·p（无透视除法）
    public func map(_ p: CGPoint) -> CGPoint {
        CGPoint(x: m[0] * p.x + m[1] * p.y + m[2],
                y: m[3] * p.x + m[4] * p.y + m[5])
    }
}
