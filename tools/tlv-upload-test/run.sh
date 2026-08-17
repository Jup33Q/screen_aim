#!/bin/bash
#
#  run.sh
#  tools/tlv-upload-test — 编译 FrameServerV2 + TLVTransport + 上传测试台并运行
#
#  用法：tools/tlv-upload-test/run.sh（需 Xcode 工具链，macOS 26+）
#
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT=/tmp/tlv-upload-test
# TLVMessageType 在 SwiftPM 里是 ScreenAimCore 模块；命令行测试台先编成同名模块（接口+动态库）再引用
xcrun swiftc -emit-module -emit-library -O -target arm64-apple-macos26.0 \
    -module-name ScreenAimCore \
    "$ROOT/../../Sources/ScreenAimCore/TLVMessageType.swift" \
    -emit-module-path /tmp/ScreenAimCore.swiftmodule \
    -o /tmp/libScreenAimCore.dylib
# 两端都用线上真实源码：服务端 FrameServerV2、客户端 TLVTransport（iOS 线上文件）
xcrun swiftc -O -target arm64-apple-macos26.0 -I /tmp -L /tmp -lScreenAimCore \
    "$ROOT/../../Sources/ScreenAim/FrameServerV2.swift" \
    "$ROOT/../../ios/AimPhone/TLVTransport.swift" \
    "$ROOT/main.swift" -o "$OUT"
cd /tmp   # 采集落盘写 cwd 的 scenes/，放 /tmp 不污染仓库
exec "$OUT"
