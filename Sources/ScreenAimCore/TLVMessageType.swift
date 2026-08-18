//
//  TLVMessageType.swift
//  ScreenAimCore — TLV 消息类型号（iOS/macOS 双端共享的线上常量）
//
//  关键约束：取值即线上协议（docs/protocol.md §11），双端必须同源；
//  接收方遇未知 type 一律忽略（TLV 通道的向后兼容机制）
//

/// TLV 单连接复用的消息路由号（iPhone ⇄ Mac，Network.framework 内置 TLV framer）
public enum TLVMessageType {
    public static let video = 0        // iPhone→Mac，JPEG 视频帧
    public static let control = 1      // 双向，控制 JSON（calib/pairingQR/mouse*/localAim/capture* 等）
    public static let envelope = 2     // 双向，Codable AimMessage 信封（JSON，新结构化消息走这里）
    public static let captureMeta = 10 // iPhone→Mac，采集 session/end 记录（JSON）
    public static let captureFrame = 11// iPhone→Mac，采集帧：[4B jsonLen][json][PNG] 复合 payload
}
