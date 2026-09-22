#!/usr/bin/env python3
"""使用真实 profile 包的 VM service 记录导航、缓存、PSS、GC 后存活量和 CPU 样本。"""
import argparse
import collections
import json
from pathlib import Path
import re
import subprocess
import time
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--serial', required=True)
parser.add_argument('--vm-info', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--cycles', type=int, default=5)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
vm = json.loads(args.vm_info.read_text())
adb = ['adb', '-s', args.serial]
http = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def rpc(method, **params):
    params['isolateId'] = vm['isolateId']
    query = urllib.parse.urlencode({k: json.dumps(v) if isinstance(v, bool) else v
                                   for k, v in params.items()})
    result = json.loads(http.open(vm['appUri'] + method + '?' + query, timeout=30).read())
    if 'error' in result:
        raise RuntimeError(result['error'])
    return result['result']


def control(action='stats'):
    return rpc('ext.gallery.perf', action=action)


def enter(scene):
    control(scene)
    for _ in range(150):
        state = control()
        current = [s for s in state['scenes'] if s['current'] and s['route'] == 'perf/' + scene]
        if current and (scene != 'near' or current[0]['map_tiles'] > 0):
            time.sleep(1.5)
            return
        time.sleep(.2)
    raise RuntimeError(f'{scene} did not become ready')


def pop():
    control('pop')
    time.sleep(1.5)


records = []


def snapshot(name):
    before = {'vm': rpc('getMemoryUsage'), 'app': control()}
    allocations = rpc('getAllocationProfile', gc=True)
    time.sleep(.4)
    after = {'vm': rpc('getMemoryUsage'), 'app': control()}
    mem = subprocess.check_output(adb + ['shell', 'dumpsys', 'meminfo', 'com.example.flutter_3d_demo'], text=True)
    (args.output / (name + '.meminfo.txt')).write_text(mem)
    (args.output / (name + '.allocations.json')).write_text(json.dumps(allocations))
    pss = re.search(r'TOTAL PSS:\s*(\d+)', mem)
    if pss is None:
        pss = re.search(r'^\s*TOTAL\s+(\d+)', mem, re.M)
    if pss is None:
        raise RuntimeError('PSS missing')
    row = {'name': name, 'pss_kb': int(pss[1]), 'before_gc': before, 'after_gc': after}
    records.append(row)
    (args.output / 'memory.json').write_text(json.dumps(records, indent=2))
    print(name, 'PSS KB', row['pss_kb'], 'heap', after['vm']['heapUsage'],
          'cache', after['app']['shared_cache'], flush=True)


def cpu(name):
    samples = rpc('getCpuSamples', timeOriginMicros=0, timeExtentMicros=10**15)
    (args.output / (name + '.cpu.json')).write_text(json.dumps(samples))
    counts = collections.Counter()
    for sample in samples.get('samples', []):
        for frame in set(sample.get('stack', [])):
            counts[frame] += 1
    top = []
    for index, count in counts.most_common(35):
        function = samples['functions'][index]['function']
        top.append({'name': function.get('name'), 'samples': count})
    (args.output / (name + '.cpu-top.json')).write_text(json.dumps(
        {'sample_count': len(samples.get('samples', [])), 'inclusive': top}, indent=2))
    print(name, 'CPU samples', len(samples.get('samples', [])), flush=True)


control('reset')
time.sleep(2)
# 统一做一次场景预热，泄漏判断比较每轮退出后的值，避免混入首次着色器初始化。
for _ in range(2):
    enter('memory')
    pop()
snapshot('warm_entry')
enter('memory')
snapshot('memory_initial')
rpc('clearCpuSamples')
for _ in range(22):
    subprocess.run(adb + ['shell', 'input', 'tap', '972', '1410'], check=True)
    time.sleep(.16)
time.sleep(2)
cpu('memory_browse')
snapshot('memory_browsed')
rpc('clearCpuSamples')
enter('near')
cpu('globe_load')
snapshot('memory_under_globe')
rpc('clearCpuSamples')
for i in range(10):
    x1, x2 = (780, 300) if i % 2 == 0 else (300, 780)
    subprocess.run(adb + ['shell', 'input', 'swipe', str(x1), '1300', str(x2), '1300', '650'], check=True)
    time.sleep(.5)
time.sleep(2)
cpu('globe_pan')
snapshot('globe_panned')
subprocess.run(adb + ['shell', 'input', 'tap', '1008', '191'], check=True)
time.sleep(3)
snapshot('globe_overview_after_detail')
pop()
snapshot('memory_returned')
pop()
snapshot('entry_after_1')
for cycle in range(2, args.cycles + 1):
    enter('memory')
    enter('near')
    pop()
    pop()
    snapshot(f'entry_after_{cycle}')
print('Profile collection complete', flush=True)
