#!/bin/bash
# iphone-linked-dev 环境自检：输出每条工具链的可用状态与修复建议
# 用法：scripts/ios_env_check.sh   退出码 0 = 模拟器路线可用，1 = 核心工具缺失

ok=0; miss=0
report() {  # $1=名称 $2=状态(OK/MISS) $3=补充说明
  if [ "$2" = "OK" ]; then printf '✅ %-14s %s\n' "$1" "$3"; ok=$((ok+1));
  else printf '❌ %-14s %s\n' "$1" "$3"; miss=$((miss+1)); fi
}

# 1) Xcode 开发者目录（决定 simctl/devicectl 是否可用）
DEVELOPER_DIR=$(xcode-select -p 2>/dev/null)
if [ -n "$DEVELOPER_DIR" ]; then report "xcode-select" OK "$DEVELOPER_DIR"; else report "xcode-select" MISS "运行 xcode-select --install"; fi

# 2) simctl（模拟器路线核心）
if xcrun simctl help >/dev/null 2>&1; then
  BOOTED=$(xcrun simctl list devices 2>/dev/null | grep -c Booted)
  report "simctl" OK "已启动模拟器: ${BOOTED} 台"
else
  report "simctl" MISS "只有 Command Line Tools；需安装完整 Xcode 并 sudo xcodebuild -license accept"
fi

# 3) devicectl（真机路线核心，Xcode 15+）
if xcrun devicectl --help >/dev/null 2>&1; then
  DEVICES=$(xcrun devicectl list devices 2>/dev/null | grep -cE 'available|paired' || true)
  report "devicectl" OK "可见设备约 ${DEVICES} 台"
else
  report "devicectl" MISS "需 Xcode 15+；真机装 App/查进程不可用"
fi

# 4) xcodebuild
if xcodebuild -version >/dev/null 2>&1; then report "xcodebuild" OK "$(xcodebuild -version 2>/dev/null | head -1)"; else report "xcodebuild" MISS "需 Xcode"; fi

# 5) idb（UI 自动化路线 A）
if command -v idb >/dev/null 2>&1 && command -v idb_companion >/dev/null 2>&1; then
  report "idb" OK "$(command -v idb)"
else
  report "idb" MISS "brew install idb-companion && pipx install fb-idb --python python3.11（勿用 Python 3.14）"
fi

# 6) WDA（UI 自动化路线 B）——只探测端口，不自动启动
if curl -sf --max-time 2 http://127.0.0.1:8100/status >/dev/null 2>&1; then
  report "WDA:8100" OK "WebDriverAgent 正在响应"
else
  report "WDA:8100" MISS "未运行；按需启动，见 references/ui-automation.md 路线 B"
fi

# 7) 辅助工具
command -v xcpretty >/dev/null 2>&1 && report "xcpretty" OK "构建输出过滤可用" || report "xcpretty" MISS "可选：brew install xcpretty（或用 grep 过滤，见 references/build-loop.md）"
command -v iproxy >/dev/null 2>&1 && report "iproxy" OK "真机 WDA 端口转发可用" || report "iproxy" MISS "真机 WDA 需要：brew install libimobiledevice"

echo "---"
echo "合计: ${ok} 项可用, ${miss} 项缺失"
xcrun simctl help >/dev/null 2>&1 || exit 1
exit 0
