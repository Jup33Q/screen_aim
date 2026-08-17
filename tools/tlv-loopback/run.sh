#!/bin/bash
#
#  run.sh
#  tools/tlv-loopback — 编译 FrameServerV2 + 回环测试并运行
#
#  用法：tools/tlv-loopback/run.sh（需 Xcode 工具链，macOS 26+）
#
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT=/tmp/tlv-loopback
# TLVMessageType 在 SwiftPM 里是 ScreenAimCore 模块；命令行测试台先编成同名模块（接口+动态库）再引用
xcrun swiftc -emit-module -emit-library -O -target arm64-apple-macos26.0 \
    -module-name ScreenAimCore \
    "$ROOT/../../Sources/ScreenAimCore/TLVMessageType.swift" \
    -emit-module-path /tmp/ScreenAimCore.swiftmodule \
    -o /tmp/libScreenAimCore.dylib
# 服务端实现直接用主 target 的 FrameServerV2.swift，保证测的是线上代码
xcrun swiftc -O -target arm64-apple-macos26.0 -I /tmp -L /tmp -lScreenAimCore \
    "$ROOT/../../Sources/ScreenAim/FrameServerV2.swift" "$ROOT/main.swift" -o "$OUT"
cd /tmp   # 采集落盘写 cwd 的 scenes/，放 /tmp 不污染仓库
exec "$OUT"
