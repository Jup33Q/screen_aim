//
//  main.swift
//  tools/ui-click — 在屏幕坐标注入一次鼠标点击（验收自动化用）
//
//  关键约束：Quartz 全局坐标（左上角原点）；运行进程需辅助功能授权
//
//  用法：ui-click <x> <y>
//

import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2]) else {
    print("用法: ui-click <x> <y>")
    exit(2)
}
let pt = CGPoint(x: x, y: y)
// 先移动光标到位再点：某些控件依赖 hover/tracking area 状态
let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                   mouseCursorPosition: pt, mouseButton: .left)
move?.post(tap: .cghidEventTap)
usleep(150_000)
for type in [CGEventType.leftMouseDown, CGEventType.leftMouseUp] {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt,
                    mouseButton: .left)
    e?.post(tap: .cghidEventTap)
    usleep(80_000)
}
print("clicked at (\(x), \(y))")
