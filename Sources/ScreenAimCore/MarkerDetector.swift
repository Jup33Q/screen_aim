//
//  MarkerDetector.swift
//  ScreenAimCore — 纯 Swift ArUco（DICT_4X4_50）标记检测器，零第三方依赖
//
//  管线：BGRA → 灰度 → 自适应阈值（积分图均值-C）→ 黑色连通域（two-pass union-find）
//        → 四边形候选（组件在 ±45° 方向的极值点即凸四边形四角）
//        → 亚像素角点精化（法向剖面 + TLS 直线拟合，Phase 1.2）
//        → 单应矫正采样 6×6 格 → 排序最大间隙阈值 → 边框环校验 + 字典 4 旋转匹配
//
//  与 Mac 端 OpenCV 管线的取舍：
//  - 亚像素精化用自研法向剖面法（OpenCV 是 CORNER_REFINE_SUBPIX），中心误差 ~0.2px 级
//  - 用"组件外圈必须亮"替代 OpenCV 的轮廓层级校验，拒绝并入暗背景的候选
//  线程约定：非线程安全，调用方需在串行队列使用（AimPhone: aimphone.capture）
//

import Foundation
import CoreGraphics

/// 检测结果：帧像素坐标（左上原点），corners 从最接近图像左上角开始按视觉顺时针排列
public struct DetectedMarker {
    public let id: Int
    public let center: CGPoint
    public let corners: [CGPoint]
}

public final class ArucoDetector {
    // MARK: 可调参数（默认值按 720p 帧、24pt 屏幕标记标定）
    public var windowSize = 23            // 自适应阈值窗口边长（奇数）
    public var thresholdC: Double = 8     // 局部均值偏移量（≥噪声幅度，否则椒盐噪声淹没二值图）
    public var minSide: Double = 8        // 候选四边形最小边长（px）
    // 组件像素数 / 四边形面积：大标记（黑格大于阈值窗口）只描出边缘轮廓环，fill≈0.2；
    // 小标记（黑格小于窗口）整体为实心，fill≈0.7。下限取 0.08 兼容两种形态，
    // 真正的伪候选过滤由位图解码（边框环 + 外圈 + 字典）完成
    public var minFillRatio = 0.08
    // 上限 1.4：极值点取的是像素中心，小实心方块的 fill 可达 (s/(s-1))²（s=8 时 ≈1.31）
    public var maxFillRatio = 1.4
    public var maxQuadAreaRatio = 0.5     // 四边形面积占整帧上限
    public var outerRingMargin: Double = 10  // 外圈亮度必须超过格网阈值这么多
    public var minCellGap: Double = 25    // 36 格最小黑白间隙（模糊帧上白格可能只剩 ~180）
    public var subpixelRefine = true      // 亚像素角点精化开关（Phase 1.2；--replay A/B 用）
    // 候选解码上限：按组件像素数降序截断。8 个真实标记通常是最干净的暗块，
    // 复杂场景（桌面文字/图标噪点成百上千）只解前 N 个，长尾直接丢弃；
    // decode 内部的边框环/外圈/字典校验会把混入的伪候选筛掉
    public var maxCandidates = 32
    public var debugLog = false           // 打印候选拒绝原因（排错用）
    /// 拒绝原因直方图（--replay 汇总用；每次拒绝一次字典递增，成本可忽略）
    public private(set) var rejectHistogram: [String: Int] = [:]
    public private(set) var lastDark: [UInt8] = []   // debugLog 时保留最近一帧的二值图
    public private(set) var lastSize: (w: Int, h: Int) = (0, 0)

    /// 清空拒绝直方图（每个回放会话开始前调用）
    public func resetRejectHistogram() { rejectHistogram.removeAll() }

    /// 统一拒绝出口：计数后返回 nil
    private func reject(_ key: String) -> DetectedMarker? {
        rejectHistogram[key, default: 0] += 1
        return nil
    }

    private var dlogPrefix = ""
    @inline(__always)
    private func dlog(_ msg: String) {
        if debugLog { FileHandle.standardError.write("  [reject\(dlogPrefix)] \(msg)\n".data(using: .utf8)!) }
    }

    // 工作缓冲区（复用，避免逐帧分配）
    private var gray: [UInt8] = []
    private var dark: [UInt8] = []
    private var integral: [UInt32] = []
    private var labels: [Int32] = []
    private var parent: [Int32] = []

    public init() {}

    // MARK: - 入口
    /// - Parameters:
    ///   - bgra: BGRA 像素数据指针
    ///   - bytesPerRow: 行字节数（允许 padding；紧凑数据传 width*4）
    public func detect(bgra: UnsafeRawPointer, width w: Int, height h: Int,
                       bytesPerRow: Int) -> [DetectedMarker] {
        guard w > 16, h > 16 else { return [] }
        prepareBuffers(w: w, h: h)
        toGray(bgra: bgra, w: w, h: h, bytesPerRow: bytesPerRow)
        buildIntegral(w: w, h: h)
        thresholdDark(w: w, h: h)
        if debugLog { lastDark = dark; lastSize = (w, h) }
        let comps = labelComponents(w: w, h: h)
        // 候选数量上限（maxCandidates）：按像素数降序取前 N 个再逐个解码，
        // 防止复杂桌面场景下成千上万个噪点组件拖垮逐候选 decode
        let capped = comps.count > maxCandidates
            ? Array(comps.sorted { $0.count > $1.count }.prefix(maxCandidates))
            : comps
        var out: [DetectedMarker] = []
        for c in capped {
            if let m = decode(candidate: c, w: w, h: h) { out.append(m) }
        }
        return out.sorted { $0.id < $1.id }
    }

    private func prepareBuffers(w: Int, h: Int) {
        let n = w * h
        if gray.count != n {
            gray = [UInt8](repeating: 0, count: n)
            dark = [UInt8](repeating: 0, count: n)
            integral = [UInt32](repeating: 0, count: (w + 1) * (h + 1))
            labels = [Int32](repeating: -1, count: n)
            parent = []
        } else {
            // labels 每帧需要重置；-1 表示背景/未标记
            labels.withUnsafeMutableBufferPointer { $0.update(repeating: -1) }
        }
    }

    // MARK: - 1. 灰度（BT.601 近似：(29B + 150G + 77R) >> 8）
    private func toGray(bgra: UnsafeRawPointer, w: Int, h: Int, bytesPerRow: Int) {
        gray.withUnsafeMutableBufferPointer { g in
            for y in 0..<h {
                let row = bgra.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                let dst = g.baseAddress! + y * w
                var x = 0
                while x < w {
                    let p = row + x * 4
                    let b = Int(p[0]), g1 = Int(p[1]), r1 = Int(p[2])
                    let luma = (29 * b + 150 * g1 + 77 * r1) >> 8
                    dst[x] = UInt8(luma)
                    x += 1
                }
            }
        }
    }

    // MARK: - 2. 积分图（(w+1)×(h+1)，I[0,*]=I[*,0]=0）
    private func buildIntegral(w: Int, h: Int) {
        let iw = w + 1
        integral.withUnsafeMutableBufferPointer { I in
            gray.withUnsafeBufferPointer { g in
                for y in 0..<h {
                    var rowSum: UInt32 = 0
                    let srcRow = y * w
                    let cur = y + 1
                    for x in 0..<w {
                        rowSum += UInt32(g[srcRow + x])
                        I[cur * iw + x + 1] = I[y * iw + x + 1] + rowSum
                    }
                }
            }
        }
    }

    /// 窗口和（边界自动收缩）。注意必须用 Int64 计算：A-B-C+D 的中间项可能为负，
    /// UInt32 直接减会下溢崩溃
    @inline(__always)
    private func windowSum(x: Int, y: Int, r: Int, w: Int, h: Int) -> (sum: UInt32, count: Int) {
        let iw = w + 1
        let x0 = max(0, x - r), x1 = min(w - 1, x + r)
        let y0 = max(0, y - r), y1 = min(h - 1, y + r)
        let s = integral.withUnsafeBufferPointer { I -> Int64 in
            Int64(I[(y1 + 1) * iw + x1 + 1]) - Int64(I[y0 * iw + x1 + 1])
                - Int64(I[(y1 + 1) * iw + x0]) + Int64(I[y0 * iw + x0])
        }
        return (UInt32(s), (x1 - x0 + 1) * (y1 - y0 + 1))
    }

    // MARK: - 3. 自适应阈值：灰度 < 局部均值 - C → 暗像素(1)
    /// 性能关键路径（逐像素）：三个缓冲指针一次性取出，循环内纯指针运算；
    /// 积分图差值用 Int64（中间项可为负，UInt32 直接减会下溢）
    private func thresholdDark(w: Int, h: Int) {
        let r = windowSize / 2
        let c = thresholdC
        let iw = w + 1
        dark.withUnsafeMutableBufferPointer { d in
            gray.withUnsafeBufferPointer { g in
                integral.withUnsafeBufferPointer { I in
                    let db = d.baseAddress!, gb = g.baseAddress!, ib = I.baseAddress!
                    for y in 0..<h {
                        let y0 = max(0, y - r), y1 = min(h - 1, y + r)
                        let rowA = (y1 + 1) * iw, rowB = y0 * iw
                        let dRow = db + y * w
                        let gRow = gb + y * w
                        for x in 0..<w {
                            let x0 = max(0, x - r), x1 = min(w - 1, x + r)
                            let sum = Int64(ib[rowA + x1 + 1]) - Int64(ib[rowB + x1 + 1])
                                    - Int64(ib[rowA + x0]) + Int64(ib[rowB + x0])
                            let count = (x1 - x0 + 1) * (y1 - y0 + 1)
                            let mean = Double(sum) / Double(count)
                            dRow[x] = Double(gRow[x]) < mean - c ? 1 : 0
                        }
                    }
                }
            }
        }
    }

    // MARK: - 4. 连通域标记（4 连通，two-pass union-find，只标记暗像素）
    private struct Component {
        var count = 0
        var minSum = CGPoint.zero   // argmin(x+y) ≈ 左上
        var maxSum = CGPoint.zero   // argmax(x+y) ≈ 右下
        var minDiff = CGPoint.zero  // argmin(x-y) ≈ 左下
        var maxDiff = CGPoint.zero  // argmax(x-y) ≈ 右上
        var minSumV = Int.max, maxSumV = Int.min
        var minDiffV = Int.max, maxDiffV = Int.min
        var touchesBorder = false
    }

    private func find(_ i: Int32) -> Int32 {
        var r = i
        while parent[Int(r)] != r { r = parent[Int(r)] }
        // 路径压缩（沿途减半）
        var j = i
        while parent[Int(j)] != j {
            let next = parent[Int(j)]
            parent[Int(j)] = r
            j = next
        }
        return r
    }

    private func labelComponents(w: Int, h: Int) -> [Component] {
        var nextLabel: Int32 = 0
        parent = [Int32](repeating: 0, count: w * h)

        dark.withUnsafeBufferPointer { d in
            labels.withUnsafeMutableBufferPointer { L in
                for y in 0..<h {
                    for x in 0..<w {
                        let idx = y * w + x
                        guard d[idx] == 1 else { continue }
                        let left: Int32 = (x > 0 && d[idx - 1] == 1) ? L[idx - 1] : -1
                        let up: Int32 = (y > 0 && d[idx - w] == 1) ? L[idx - w] : -1
                        if left < 0 && up < 0 {
                            L[idx] = nextLabel
                            parent[Int(nextLabel)] = nextLabel
                            nextLabel += 1
                        } else if left >= 0 && up < 0 {
                            L[idx] = find(left)
                        } else if up >= 0 && left < 0 {
                            L[idx] = find(up)
                        } else {
                            let a = find(left), b = find(up)
                            if a != b { parent[Int(max(a, b))] = min(a, b) }
                            L[idx] = min(a, b)
                        }
                    }
                }
            }
        }

        // 第二遍：按根聚合统计
        var compIndex: [Int32: Int] = [:]
        var comps: [Component] = []
        for y in 0..<h {
            for x in 0..<w {
                let idx = y * w + x
                guard dark[idx] == 1 else { continue }
                let root = find(labels[idx])
                let ci: Int
                if let existing = compIndex[root] {
                    ci = existing
                } else {
                    ci = comps.count
                    compIndex[root] = ci
                    comps.append(Component())
                }
                comps[ci].count += 1
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { comps[ci].touchesBorder = true }
                let p = CGPoint(x: x, y: y)
                let s = x + y, df = x - y
                if s < comps[ci].minSumV { comps[ci].minSumV = s; comps[ci].minSum = p }
                if s > comps[ci].maxSumV { comps[ci].maxSumV = s; comps[ci].maxSum = p }
                if df < comps[ci].minDiffV { comps[ci].minDiffV = df; comps[ci].minDiff = p }
                if df > comps[ci].maxDiffV { comps[ci].maxDiffV = df; comps[ci].maxDiff = p }
            }
        }
        return comps
    }

    // MARK: - 5/6/7. 候选过滤 → 四边形排序 → 位图解码
    private func decode(candidate c: Component, w: Int, h: Int) -> DetectedMarker? {
        dlogPrefix = " @(\(Int((c.minSum.x + c.maxSum.x) / 2)),\(Int((c.minSum.y + c.maxSum.y) / 2))) n=\(c.count)"
        let big = c.count >= 100
        if debugLog && big {
            FileHandle.standardError.write("  [cand] count=\(c.count) extremes sum[\(c.minSumV),\(c.maxSumV)] diff[\(c.minDiffV),\(c.maxDiffV)] border=\(c.touchesBorder)\n".data(using: .utf8)!)
        }
        if c.touchesBorder {
            dlog("touchesBorder count=\(c.count) bbox=(\(Int(c.minDiff.x)),\(Int(c.minSum.y)))-(\(Int(c.maxDiff.x)),\(Int(c.maxSum.y)))")
            return reject("touchesBorder")
        }

        // 极值点 → 四顶点（凸四边形的 ±45° 方向极值即四个角）
        var pts = [c.minSum, c.maxDiff, c.maxSum, c.minDiff]
        // 去重（退化组件）
        var uniq: [CGPoint] = []
        for p in pts where !uniq.contains(where: { abs($0.x - p.x) + abs($0.y - p.y) < 1 }) {
            uniq.append(p)
        }
        guard uniq.count == 4 else { if big { dlog("corners=\(uniq.count)") }; return reject("corners") }
        pts = uniq

        // 绕质心按 atan2 排序（图像 y 向下时等同于视觉顺时针），再从最接近左上角者开始
        let cx = pts.reduce(0) { $0 + $1.x } / 4
        let cy = pts.reduce(0) { $0 + $1.y } / 4
        pts.sort { atan2($0.y - cy, $0.x - cx) < atan2($1.y - cy, $1.x - cx) }
        var start = 0
        for i in 1..<4 where pts[i].x + pts[i].y < pts[start].x + pts[start].y { start = i }
        pts = (0..<4).map { pts[(start + $0) % 4] }

        // 凸性：相邻边叉积同号
        var crossSign = 0
        for i in 0..<4 {
            let a = pts[i], b = pts[(i + 1) % 4], d = pts[(i + 2) % 4]
            let cross = (b.x - a.x) * (d.y - b.y) - (b.y - a.y) * (d.x - b.x)
            if abs(cross) < 1 { if big { dlog("degenerate cross=\(cross)") }; return reject("degenerate") }
            let sign = cross > 0 ? 1 : -1
            if crossSign == 0 { crossSign = sign } else if sign != crossSign { if big { dlog("concave") }; return reject("concave") }
        }

        // 边长与面积过滤
        var sides: [Double] = []
        for i in 0..<4 {
            sides.append(hypot(pts[(i + 1) % 4].x - pts[i].x, pts[(i + 1) % 4].y - pts[i].y))
        }
        guard sides.allSatisfy({ $0 >= minSide }) else { return reject("minSide") }   // 小噪声太多，不记录
        let quadArea = 0.5 * abs(
            (pts[0].x * pts[1].y + pts[1].x * pts[2].y + pts[2].x * pts[3].y + pts[3].x * pts[0].y)
          - (pts[1].x * pts[0].y + pts[2].x * pts[1].y + pts[3].x * pts[2].y + pts[0].x * pts[3].y))
        guard quadArea <= Double(w * h) * maxQuadAreaRatio else { dlog("quadArea=\(Int(quadArea)) too big"); return reject("quadArea") }
        let fill = Double(c.count) / quadArea
        guard fill >= minFillRatio && fill <= maxFillRatio else {
            dlog("fill=\(String(format: "%.2f", fill)) count=\(c.count) quadArea=\(Int(quadArea))"); return reject("fill")
        }

        // 亚像素角点精化（Phase 1.2）：法向剖面 + TLS 直线拟合。
        // NOTE: 极值角点来自暗组件像素中心，系统性偏内 ~0.5px，精化同时修正该偏移；
        // 小标记（帧上 <20px）角点偏 1px 就会把 6×6 格采样压到边框环上导致解码失败，
        // 这是 20pt 远距标记命中率低的主因之一
        if subpixelRefine { pts = refineCorners(pts, w: w, h: h) }

        // 单应：规范 6×6 格坐标 → 图像四边形（corners 顺序一致，采样结果只差整体旋转）
        guard let H = Homography(src: [CGPoint(x: 0, y: 0), CGPoint(x: 6, y: 0),
                                       CGPoint(x: 6, y: 6), CGPoint(x: 0, y: 6)],
                                 dst: pts) else { return reject("homography") }
        func sampleCell(_ col: Double, _ row: Double) -> Double {
            let p = H.map(CGPoint(x: col, y: row))
            return sampleGray(x: p.x, y: p.y, w: w, h: h)
        }

        // 采 6×6 格中心
        var cell = [Double](repeating: 0, count: 36)
        for r in 0..<6 {
            for cl in 0..<6 {
                cell[r * 6 + cl] = sampleCell(Double(cl) + 0.5, Double(r) + 0.5)
            }
        }
        guard let thr = gapThreshold(cell) else { dlog("threshold failed (无双峰对比)"); return reject("threshold") }

        // 边框环必须全黑（低于阈值）
        for r in 0..<6 {
            for cl in 0..<6 where r == 0 || r == 5 || cl == 0 || cl == 5 {
                if cell[r * 6 + cl] >= thr { dlog("border(\(r),\(cl))=\(Int(cell[r*6+cl])) >= thr=\(Int(thr))"); return reject("border") }
            }
        }
        // 外圈（标记外的白色底卡环）必须明显亮——拒绝并入暗背景的实心块
        var outerSum = 0.0
        for i in 0..<6 {
            outerSum += sampleCell(Double(i) + 0.5, -0.5)
            outerSum += sampleCell(Double(i) + 0.5, 6.5)
            if i > 0 && i < 5 {
                outerSum += sampleCell(-0.5, Double(i) + 0.5)
                outerSum += sampleCell(6.5, Double(i) + 0.5)
            }
        }
        guard outerSum / 20 > thr + outerRingMargin else {
            dlog("outerRing=\(Int(outerSum/20)) thr=\(Int(thr))"); return reject("outerRing")
        }

        // 内层 4×4 打包（亮=1），4 旋转查字典
        var bits: UInt16 = 0
        for r in 1...4 {
            for cl in 1...4 {
                bits <<= 1
                if cell[r * 6 + cl] > thr { bits |= 1 }
            }
        }
        guard let hit = ArucoDictionary.lookup(bits) else {
            dlog(String(format: "bits=0x%04X not in dict", bits)); return reject("dict")
        }

        let center = CGPoint(x: pts.reduce(0) { $0 + $1.x } / 4,
                             y: pts.reduce(0) { $0 + $1.y } / 4)
        return DetectedMarker(id: hit.id, center: center, corners: pts)
    }

    // MARK: - 8. 亚像素角点精化（法向剖面 + TLS 直线拟合）
    /// 对四边各取 12 个采样点，沿边法向 ±halfNorm 双线性采灰度，梯度最大位置做
    /// 加权质心得亚像素边缘点；每边 12 点 TLS（总体最小二乘）直线拟合，
    /// 相邻直线求交得精化角点。任何一步不可靠都回退原角点，保证不劣化。
    private func refineCorners(_ pts: [CGPoint], w: Int, h: Int) -> [CGPoint] {
        struct Line { var p: CGPoint; var d: CGPoint }   // 直线上一点 + 单位方向
        var lines: [Line] = []
        for i in 0..<4 {
            let a = pts[i], b = pts[(i + 1) % 4]
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len >= minSide else { return pts }
            let dir = CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len)
            let nrm = CGPoint(x: -dir.y, y: dir.x)
            let halfNorm = min(5.0, len / 4)      // 小标记收窄法向范围，避免采到对侧边
            let kMax = max(3, Int(halfNorm.rounded()))
            var edgePts: [CGPoint] = []
            for s in 0..<12 {
                let t = 0.2 + 0.6 * Double(s) / 11   // 避开角点区（角部剖面不干净）
                let px = a.x + (b.x - a.x) * t, py = a.y + (b.y - a.y) * t
                // 法向灰度剖面（2·kMax+1 点，复用双线性采样）
                var prof = [Double](repeating: 0, count: 2 * kMax + 1)
                for k in 0...(2 * kMax) {
                    let off = halfNorm * Double(k - kMax) / Double(kMax)
                    prof[k] = sampleGray(x: px + nrm.x * off, y: py + nrm.y * off, w: w, h: h)
                }
                // 中心差分梯度：取**离剖面中心最近**的强峰——剖面中心在极值点连边上，
                // 真外缘距中心 ≤~1px； WARNING: 不能取全局最大峰，边框环内侧的白格
                // 在 ±5px 剖面内会造成第二处过渡，取错会把边拟到标记内部一格
                var grad = [Double](repeating: 0, count: prof.count)
                for k in 1..<(prof.count - 1) { grad[k] = abs(prof[k + 1] - prof[k - 1]) }
                var kPeak = -1
                for k in 1..<(prof.count - 1) where grad[k] > 12 {
                    if kPeak < 0 || abs(k - kMax) < abs(kPeak - kMax) { kPeak = k }
                }
                guard kPeak > 0 else { continue }   // 无清晰边缘（模糊/噪声），弃用该采样点
                // 峰值 ±1 邻域按梯度加权质心 → 亚像素边缘位置
                var wsum = 0.0, ksum = 0.0
                for k in max(1, kPeak - 1)...min(prof.count - 2, kPeak + 1) {
                    wsum += grad[k]
                    ksum += grad[k] * Double(k)
                }
                guard wsum > 0 else { continue }
                let off = halfNorm * (ksum / wsum - Double(kMax)) / Double(kMax)
                edgePts.append(CGPoint(x: px + nrm.x * off, y: py + nrm.y * off))
            }
            guard edgePts.count >= 6 else { return pts }   // 有效剖面太少，整体回退
            // TLS 直线拟合：方向 = 协方差阵主特征向量（2×2 闭式解）
            let n = Double(edgePts.count)
            let mx = edgePts.reduce(0.0) { $0 + $1.x } / n
            let my = edgePts.reduce(0.0) { $0 + $1.y } / n
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for p in edgePts {
                let dx = p.x - mx, dy = p.y - my
                sxx += dx * dx; syy += dy * dy; sxy += dx * dy
            }
            guard sxx + syy > 1e-9 else { return pts }   // 边缘点退化重合
            let theta = 0.5 * atan2(2 * sxy, sxx - syy)
            lines.append(Line(p: CGPoint(x: mx, y: my),
                              d: CGPoint(x: cos(theta), y: sin(theta))))
        }
        // 相邻直线求交得角点：角 i = 边(i-1) ∩ 边(i)
        var refined: [CGPoint] = []
        for i in 0..<4 {
            let l1 = lines[(i + 3) % 4], l2 = lines[i]
            let cross = l1.d.x * l2.d.y - l1.d.y * l2.d.x
            guard abs(cross) > 1e-6 else { return pts }   // 平行退化，整体回退
            let t = ((l2.p.x - l1.p.x) * l2.d.y - (l2.p.y - l1.p.y) * l2.d.x) / cross
            let c = CGPoint(x: l1.p.x + l1.d.x * t, y: l1.p.y + l1.d.y * t)
            // 移动超过 3px 说明剖面拟合不可靠（采到了别的结构），保留原角点
            let o = pts[i]
            refined.append(hypot(c.x - o.x, c.y - o.y) <= 3 ? c : o)
        }
        return refined
    }

    /// 双线性灰度采样（坐标钳到图像内；非有限值来自退化单应，按 0 处理）
    private func sampleGray(x: Double, y: Double, w: Int, h: Int) -> Double {
        guard x.isFinite, y.isFinite else { return 0 }
        let xc = min(max(x, 0), Double(w - 1)), yc = min(max(y, 0), Double(h - 1))
        let x0 = Int(xc), y0 = Int(yc)
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let fx = xc - Double(x0), fy = yc - Double(y0)
        return gray.withUnsafeBufferPointer { g in
            let v00 = Double(g[y0 * w + x0]), v10 = Double(g[y0 * w + x1])
            let v01 = Double(g[y1 * w + x0]), v11 = Double(g[y1 * w + x1])
            return (v00 * (1 - fx) + v10 * fx) * (1 - fy) + (v01 * (1 - fx) + v11 * fx) * fy
        }
    }

    /// 36 个样本的排序最大间隙阈值：真实标记黑白双峰分明，阈值取最大间隙中点。
    /// 比 Otsu 稳——模糊帧上 Otsu 会把阈值贴到暗簇边缘，边框格相等即误判。
    /// 最大间隙 < 40（对比不足，非标记）返回 nil
    private func gapThreshold(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard sorted.count == 36 else { return nil }
        var bestGap = 0.0, bestIdx = -1
        for i in 0..<(sorted.count - 1) {
            let gap = sorted[i + 1] - sorted[i]
            if gap > bestGap { bestGap = gap; bestIdx = i }
        }
        guard bestGap >= minCellGap, bestIdx >= 0 else { return nil }
        return (sorted[bestIdx] + sorted[bestIdx + 1]) / 2
    }
}
