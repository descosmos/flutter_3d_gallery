#!/usr/bin/env python3
"""采集已打开场景的 FrameTiming；ADB 明确指定设备，首尾各裁去 1 秒。

先安装 tool/frame_probe.dart 的 release 包并打开目标场景，再运行此脚本。
输出仅为 Flutter UI/Raster 耗时，不等同于屏幕最终呈现帧率。
"""
import argparse
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--seconds', type=float, default=22)
    parser.add_argument('--swipe-y', type=int)
    parser.add_argument('--tap-cycle', action='store_true', help='20 次下一张后 20 次上一张')
    parser.add_argument('--settle-seconds', type=float, default=3)
    parser.add_argument('--start-delay', type=float, default=2)
    parser.add_argument('--trim-seconds', type=float, default=1)
    args = parser.parse_args()
    adb = ['adb', '-s', args.serial]
    pid = subprocess.check_output(adb + ['shell', 'pidof', 'com.example.flutter_3d_demo'], text=True).strip()
    if not pid.isdigit():
        raise SystemExit(f'无法确定应用 PID: {pid!r}')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.with_suffix('.log').open('w') as log:
        proc = subprocess.Popen(adb + ['logcat', f'--pid={pid}', '-v', 'raw', '-T', '1', 'flutter:I', '*:S'], stdout=log)
        start = time.monotonic()
        next_swipe = start + args.start_delay
        count = 0
        try:
            while time.monotonic() - start < args.seconds:
                if proc.poll() is not None:
                    raise RuntimeError('logcat 提前退出')
                if args.tap_cycle and time.monotonic() >= next_swipe and count < 40:
                    x = 972 if count < 20 else 108
                    subprocess.run(adb + ['shell', 'input', 'tap', str(x), '1410'], check=True, timeout=8)
                    count += 1
                    next_swipe += .5
                elif args.swipe_y is not None and time.monotonic() >= next_swipe:
                    x1, x2 = (840, 240) if count % 2 == 0 else (240, 840)
                    subprocess.run(adb + ['shell', 'input', 'swipe', str(x1), str(args.swipe_y), str(x2), str(args.swipe_y), '650'], check=True, timeout=8)
                    count += 1
                    next_swipe += 1.6
                time.sleep(0.05)
        finally:
            proc.terminate()
            proc.wait(timeout=5)
    raw = args.output.with_suffix('.log').read_text()
    frames = [json.loads(m) for m in re.findall(r'GALLERY_FRAME (\[[^\n]+\])', raw)]
    if not frames:
        raise SystemExit('没有 FrameTiming 数据；检查是否安装了探针包以及场景是否有动画')
    # FrameTiming 的批量回调有延迟，裁去首尾各 1 秒，并保存所有原始帧。
    trim = args.trim_seconds * 1000000
    lo, hi = min(f[0] for f in frames) + trim, max(f[0] for f in frames) - trim
    sampled = [f for f in frames if lo <= f[0] <= hi]
    if len(sampled) < 10:
        raise SystemExit('有效动画帧不足 10；不能计算可靠分位数')

    def metrics(values):
        values = sorted(v / 1000 for v in values)
        return {'mean_ms': statistics.mean(values),
                'p95_ms': values[math.ceil(len(values) * .95) - 1],
                'p99_ms': values[math.ceil(len(values) * .99) - 1]}

    stages = [max(f[1], f[2]) for f in sampled]
    result = {'pid': pid, 'serial': args.serial, 'frames': len(sampled),
              'swipes': 0 if args.tap_cycle else count,
              'taps': count if args.tap_cycle else 0,
              'settle_seconds': args.settle_seconds,
              'span_seconds': (sampled[-1][0] - sampled[0][0]) / 1e6,
              'build': metrics([f[1] for f in sampled]),
              'raster': metrics([f[2] for f in sampled]),
              'slowest_stage': metrics(stages),
              'over_8_33ms_percent': 100 * sum(v > 1000000 / 120 for v in stages) / len(stages),
              'over_16_67ms_percent': 100 * sum(v > 1000000 / 60 for v in stages) / len(stages)}
    args.output.with_suffix('.json').write_text(json.dumps(result, indent=2) + '\n')
    args.output.with_suffix('.frames.json').write_text(json.dumps(sampled) + '\n')
    time.sleep(args.settle_seconds)
    memory = subprocess.check_output(adb + ['shell', 'dumpsys', 'meminfo', 'com.example.flutter_3d_demo'], text=True)
    args.output.with_suffix('.meminfo.txt').write_text(memory)
    print(json.dumps(result, indent=2), flush=True)


if __name__ == '__main__':
    main()
