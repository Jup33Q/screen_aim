#!/usr/bin/env python3
# tools/ping_probe.py — 双目标 ping 时序采集（验收排障用，非交付代码）
# 同时 ping 手机(link-local v6)与路由器(v4)，逐包打 Unix 时间戳，
# 输出 RTT 分位数、>50ms 尖峰事件表、丢包簇，用于判断陡增的周期性与归属（手机侧/空口）。
import subprocess, sys, time, threading, re, statistics

PHONE = "fe80::14ca:8be7:bf5e:b036%en0"
AP = "192.168.31.1"
DUR = float(sys.argv[1]) if len(sys.argv) > 1 else 60.0
INT = "0.1"

def probe(cmd, sink, stop_at):
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True)
    for line in p.stdout:
        m = re.search(r"time[=<]([0-9.]+)\s*ms", line)
        if m:
            sink.append((time.time(), float(m.group(1))))
        elif "no answer" in line or "Request timeout" in line:
            sink.append((time.time(), None))
        if time.time() > stop_at:
            p.kill(); break
    p.wait()

def report(name, samples, t0):
    ok = [r for _, r in samples if r is not None]
    loss = [t for t, r in samples if r is None]
    n = len(samples)
    print(f"\n== {name}: {n} 包, 丢包 {len(loss)} ({100*len(loss)/max(n,1):.1f}%)")
    if ok:
        ok.sort()
        q = lambda p: ok[min(len(ok)-1, int(len(ok)*p))]
        print(f"   RTT min/p50/p90/p99/max = {ok[0]:.1f}/{q(.5):.1f}/{q(.9):.1f}/{q(.99):.1f}/{ok[-1]:.1f} ms")
    spikes = [(t-t0, r) for t, r in samples if r is not None and r > 50]
    print(f"   >50ms 尖峰 {len(spikes)} 次:", ", ".join(f"{t:.1f}s:{r:.0f}ms" for t, r in spikes[:40]))
    if loss:
        print("   丢包时刻:", ", ".join(f"{t-t0:.1f}s" for t in loss[:40]))

t0 = time.time()
phone, ap = [], []
stop = t0 + DUR
t1 = threading.Thread(target=probe, args=(["ping6", "-i", INT, PHONE], phone, stop))
t2 = threading.Thread(target=probe, args=(["ping", "-i", INT, AP], ap, stop))
t1.start(); t2.start(); t1.join(); t2.join()
report("iPhone (ping6 link-local)", phone, t0)
report("路由器 192.168.31.1 (对照)", ap, t0)
