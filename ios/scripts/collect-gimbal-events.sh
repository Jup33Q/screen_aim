#!/bin/bash
# 云台按键事件自动采集脚本（AimPhone / DockKit / Insta360 Flow 2 Pro）
#
# 用法: ./collect-gimbal-events.sh [每段秒数，默认 10]
#
# 流程：重启 App → 按时间轴语音提示按键动作 →（可选）抓取系统日志 → 提示截屏
# 事件双通道：
#   1. App 屏幕上的调试面板（时间戳事件历史，新事件在前）——主通道，采集完截屏即可
#   2. 系统日志 os_log（category=Gimbal）——WiFi pairing 可用时自动抓取

set -u
DEVICE="C8455114-3D2A-5809-8BDD-54AA740F0542"
BUNDLE="com.screenaim.AimPhone"
SEG="${1:-10}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

LOG="/tmp/gimbal_events_$(date +%H%M%S).log"
SYSLOG_PID=""

cleanup() {
    [ -n "$SYSLOG_PID" ] && kill "$SYSLOG_PID" 2>/dev/null
}
trap cleanup EXIT

say_step() {  # 时间轴提示（终端 + 系统语音，方便双手操作云台）
    echo ""
    echo ">>> $1"
    say "$2" 2>/dev/null &
}

echo "=== 云台事件采集（每段 ${SEG}s，共 7 段）==="

# 1. 重启 App（订阅流从零开始，事件历史清空）
PID=$(xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null | grep -i "AimPhone" | awk '{print $1}' | head -1)
if [ -n "$PID" ]; then
    xcrun devicectl device process terminate --device "$DEVICE" --pid "$PID" >/dev/null 2>&1
    sleep 2
fi
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" 2>&1 | grep -i launched

# 2. 尽力抓取系统日志（pairing 掉线时跳过，不影响主流程）
idevicesyslog > "$LOG" 2>&1 &
SYSLOG_PID=$!
sleep 3
if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 1 ]; then
    echo "系统日志通道已建立: $LOG"
else
    echo "提示：系统日志通道不可用（iPhone 可能锁屏），本次只看屏幕调试面板"
    cleanup; SYSLOG_PID=""
fi

sleep 4   # 等待 dock 订阅建立

# 3. 时间轴引导按键
say_step "第 1 段：什么都不按，采集基线" "什么都不按"
sleep "$SEG"
say_step "第 2 段：【按住扳机】3 秒后松开，重复两次" "按住扳机三秒，松开，再来一次"
sleep "$SEG"
say_step "第 3 段：按一下【快门键】" "按快门键"
sleep "$SEG"
say_step "第 4 段：按一下【翻转键】" "按翻转键"
sleep "$SEG"
say_step "第 5 段：转动【轮盘】几下" "转动轮盘"
sleep "$SEG"
say_step "第 6 段：【按住扳机】+ 转轮盘" "按住扳机，转轮盘"
sleep "$SEG"
say_step "第 7 段：【按住扳机】+ 按快门 / 翻转" "按住扳机，按快门和翻转"
sleep "$SEG"

cleanup
SYSLOG_PID=""

# 4. 结果汇总
echo ""
echo "=== 采集结束 ==="
if [ -s "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 1 ]; then
    echo "--- 系统日志中的云台事件 ---"
    grep -E "AimPhone\(Gimbal\)" "$LOG" | sed -E 's/^.*<Notice>: //; s/^.*<Error>: /[错误] /' | head -60
    echo "（原始日志: $LOG）"
else
    echo "系统日志无数据（不影响）——请直接看 iPhone 屏幕上的事件历史面板"
fi
echo ""
say_step "请把 iPhone 屏幕【截屏】发给我（电源键+音量上），事件历史面板里有完整记录" "请截屏发给我"
