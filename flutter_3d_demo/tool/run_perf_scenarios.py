#!/usr/bin/env python3
"""在相同设备/探针 APK 上重复受控 release 场景，并保留原始帧、PSS、温度与 Perfetto。"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--serial', required=True)
parser.add_argument('--apk', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--repeats', type=int, default=3)
parser.add_argument('--scenes', default='memory_swipe,memory_buttons,globe,near')
parser.add_argument('--trace-config', type=Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parents[1]
adb = ['adb', '-s', args.serial]
app = 'com.example.flutter_3d_demo'
routes = {'memory_swipe': '/probe/interactive', 'memory_buttons': '/probe/interactive',
          'globe': '/probe/globe', 'near': '/probe/globe/2.012',
          'near_loading': '/probe/globe/2.012'}
subprocess.run(adb + ['install', '-r', str(args.apk)], check=True)
if args.trace_config:
    subprocess.run(adb + ['push', str(args.trace_config), '/data/local/tmp/gallery-performance.pbtxt'], check=True)
settings = {key: subprocess.check_output(adb + ['shell', 'settings', 'get', 'system', key], text=True).strip()
            for key in ['min_refresh_rate', 'peak_refresh_rate']}
manifest = {'serial': args.serial, 'apk': str(args.apk), 'sha256': hashlib.sha256(args.apk.read_bytes()).hexdigest(),
            'repeats': args.repeats, 'seconds': 22, 'settings': settings, 'scenarios': args.scenes.split(',')}
(args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
all_results = []
for repeat in range(1, args.repeats + 1):
    for scene in args.scenes.split(','):
        name = f'{scene}-{repeat}'
        prefix = args.output / name
        subprocess.run(adb + ['shell', 'am', 'force-stop', app], check=True)
        begin = time.monotonic()
        subprocess.run(adb + ['shell', 'am', 'start', '-W', '-n', app + '/.MainActivity',
                              '--es', 'route', routes[scene]], check=True, stdout=subprocess.DEVNULL)
        pid = subprocess.check_output(adb + ['shell', 'pidof', app], text=True).strip()
        ready_marker = 'GALLERY_MAP_READY globe' if scene == 'near' else 'GALLERY_GPU_READY'
        for _ in range(100):
            log = subprocess.check_output(adb + ['logcat', '-d', f'--pid={pid}', '-v', 'brief', '-s', 'flutter'], text=True)
            if ready_marker in log:
                break
            time.sleep(.2)
        else:
            raise RuntimeError(f'{scene} never became ready')
        if scene == 'near' and not re.search(r'GALLERY_MAP_READY globe .*failed=0', log):
            raise RuntimeError('Incomplete map imagery; do not compare this run')
        ready_seconds = time.monotonic() - begin
        prefix.with_suffix('.startup.log').write_text('\n'.join(x for x in log.splitlines() if 'GALLERY_FRAME' not in x))
        if scene != 'near_loading':
            time.sleep(3)
        thermal = subprocess.check_output(adb + ['shell', 'dumpsys', 'thermalservice'], text=True)
        prefix.with_suffix('.thermal.txt').write_text(thermal)
        if not re.search(r'Thermal Status: 0\b', thermal):
            raise RuntimeError('Device thermal status is not nominal')
        with prefix.with_suffix('.png').open('wb') as image:
            subprocess.run(adb + ['exec-out', 'screencap', '-p'], stdout=image, check=True)
        trace = None
        trace_log = None
        if args.trace_config and repeat == 1:
            trace_log = prefix.with_suffix('.perfetto.log').open('w')
            trace_path = '/data/misc/perfetto-traces/gallery-perf-' + name + '.pftrace'
            # 云机 ADB 不转发 stdin EOF；设备内管道同时避免 perfetto 读取 shell_data_file 的限制。
            trace = subprocess.Popen(adb + ['shell',
                'cat /data/local/tmp/gallery-performance.pbtxt | perfetto --txt -c - -o ' + shlex.quote(trace_path)],
                stdout=trace_log, stderr=subprocess.STDOUT)
            time.sleep(.5)
        command = ['python3', str(root / 'tool/collect_frames.py'), '--serial', args.serial,
                   '--output', str(prefix), '--seconds', '22']
        command += ['--tap-cycle'] if scene == 'memory_buttons' else ['--swipe-y', '1300']
        if scene == 'near_loading':
            command += ['--start-delay', '0', '--trim-seconds', '0']
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
        if trace is not None:
            result = trace.wait(timeout=30)
            trace_log.close()
            if result != 0:
                raise RuntimeError('Perfetto capture failed')
            subprocess.run(adb + ['pull', trace_path, str(prefix.with_suffix('.perfetto-trace'))],
                           check=True, stdout=subprocess.DEVNULL)
        data = json.loads(prefix.with_suffix('.json').read_text())
        expected_actions = data['taps'] == 40 if scene == 'memory_buttons' else data['swipes'] == (14 if scene == 'near_loading' else 13)
        if not expected_actions:
            raise RuntimeError(f'{name}: action count differs')
        mem = prefix.with_suffix('.meminfo.txt').read_text()
        pss = re.search(r'TOTAL PSS:\s*(\d+)', mem) or re.search(r'^\s*TOTAL\s+(\d+)', mem, re.M)
        if pss is None:
            raise RuntimeError('PSS missing')
        row = {'scene': scene, 'repeat': repeat, 'ready_seconds': ready_seconds,
               'pss_kb': int(pss[1]), **data}
        all_results.append(row)
        (args.output / 'results.json').write_text(json.dumps(all_results, indent=2) + '\n')
        print(name, 'UI P95', data['build']['p95_ms'], 'Raster P95', data['raster']['p95_ms'],
              'PSS KB', row['pss_kb'], 'frames', data['frames'], flush=True)
print('All scenarios collected', flush=True)
