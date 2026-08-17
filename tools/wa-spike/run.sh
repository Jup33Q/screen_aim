#!/bin/bash
#
#  run.sh
#  tools/wa-spike — 编译尖刺程序、包成 .app、ad-hoc 签名并运行
#
#  用法：tools/wa-spike/run.sh（需 Xcode 工具链，macOS 26+）
#
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/WASpike.app"
BIN="$APP/Contents/MacOS/waspike"

# 编译（须以 macOS 26 SDK 编，WiFiAware 仅 26+ SDK 暴露）
xcrun swiftc -O -target arm64-apple-macos26.0 "$ROOT/main.swift" -o "$BIN.tmp"

# 组包
mkdir -p "$APP/Contents/MacOS"
mv "$BIN.tmp" "$BIN"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>WASpike</string>
    <key>CFBundleIdentifier</key><string>com.screenaim.waspike</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>waspike</string>
    <key>WiFiAwareServices</key>
    <dict>
        <key>_aimphone-wa._tcp</key>
        <dict>
            <key>Publishable</key><dict/>
            <key>Subscribable</key><dict/>
        </dict>
    </dict>
</dict>
</plist>
EOF

# ad-hoc 签名（尖刺足够；正式包壳时换开发者证书）
codesign --force --sign - "$APP"

# 运行：直接 exec 包内二进制，Bundle.main 仍解析到 .app
"$BIN"
