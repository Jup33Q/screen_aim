//
//  AimMessage.swift
//  ScreenAimCore — TLV type 2 信封：双端共享的结构化控制消息（Codable enum）
//
//  关键约束：线上格式为 Swift 默认 enum Codable 编码（JSONEncoder），
//  例如 {"aimUIHover":{"overlapping":true}}；取值即线上协议（docs/protocol.md §11），
//  双端同源；新增 case 只加不改，旧端解码失败即忽略（向后兼容机制）
//

/// TLV type 2 信封消息（iPhone ⇄ Mac，Network.framework 内置 TLV framer 承载）
public enum AimMessage: Codable, Sendable {
    /// 白点与 ScreenAim 悬浮 UI（顶部控制面板 / 定位码白卡）重叠状态翻转
    ///（Mac → iPhone，边沿触发；iPhone 端进入重叠时震动反馈一次）
    case aimUIHover(overlapping: Bool)
}
