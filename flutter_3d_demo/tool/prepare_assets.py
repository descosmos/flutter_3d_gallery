#!/usr/bin/env python3
"""保留原图，为演示生成尺寸受控的照片和缩略图，并记录缺图替代关系。

仅处理本地旅行素材；缺图就近匹配不代表恢复了该 GPS 点的原始照片。
macOS 运行：python3 tool/prepare_assets.py
"""
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
BACKUP = ROOT.parent / '.local_assets' / 'originals'
CACHE = ROOT.parent / '.local_assets' / 'resized'


def canonical(name):
    return re.sub(r'-[0-9a-f]{12}(?=\.jpg$)', '', name)


def distance(a, b):
    lat1, lon1, lat2, lon2 = map(math.radians, (*a, *b))
    h = math.sin((lat1 - lat2) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon1 - lon2) / 2) ** 2
    return 2 * math.asin(math.sqrt(min(1, h)))


def main():
    photos = ROOT / 'assets' / 'photos'
    thumbs = ROOT / 'assets' / 'thumbs'
    # 首次运行先完整备份；重复运行始终从原图派生，避免重复 JPEG 压缩。
    if not BACKUP.exists():
        if not list(photos.glob('*.jpg')):
            raise SystemExit('assets/photos 中没有原图')
        shutil.copytree(photos, BACKUP)
    originals = {p.name: p for p in sorted(BACKUP.glob('*.jpg'))}
    geo = {
        name: (float(lat), float(lng))
        for name, lat, lng in re.findall(
            r"'assets/thumbs/([^']+)': GeoPoint\(([-\d.]+), ([-\d.]+)\)",
            (ROOT / 'lib/story/photo_geo.dart').read_text(),
        )
    }
    if len(geo) != 632:
        raise SystemExit(f'GPS 清单解析结果异常：{len(geo)}')
    normalized = {canonical(n): n for n in originals}
    located = {n: geo.get(n, geo.get(canonical(n))) for n in originals}
    located = {n: p for n, p in located.items() if p is not None}
    story = {
        f'IMG_{n}.jpg'
        for n in re.findall(r"_p\('([^']+)'\)", (ROOT / 'lib/story/story_models.dart').read_text())
    }
    for source in (ROOT / 'lib').rglob('*.dart'):
        story.update(re.findall(r"assets/photos/([A-Za-z0-9_.-]+\.jpg)", source.read_text()))
    mappings = {}
    for name in sorted(set(geo) | story):
        if name in originals:
            src, method = name, 'exact'
        elif canonical(name) in normalized:
            src, method = normalized[canonical(name)], 'same_capture_name'
        else:
            if name not in geo or not located:
                raise SystemExit(f'无法匹配素材：{name}')
            src = min(located, key=lambda n: (distance(geo[name], located[n]), n))
            method = 'nearby_demo_replacement'
        mappings[name] = {'source': src, 'method': method}
        if method == 'nearby_demo_replacement':
            mappings[name]['distance_km'] = round(distance(geo[name], located[src]) * 6371, 3)
    CACHE.mkdir(parents=True, exist_ok=True)
    photos.mkdir(exist_ok=True)
    thumbs.mkdir(exist_ok=True)

    def materialize(src, target, size):
        cache = CACHE / f'{size}-{src}'
        if not cache.exists():
            subprocess.run(
                ['sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '85',
                 '-Z', str(size), str(originals[src]), '--out', str(cache)],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            )
        shutil.copyfile(cache, target)

    for name in originals:
        materialize(name, photos / name, 1440)
    for name in sorted(story):
        materialize(mappings[name]['source'], photos / name, 1440)
    for name in sorted(geo):
        materialize(mappings[name]['source'], thumbs / name, 512)
    receipt = {
        'description': '缺失项使用同次旅行中位置最近的现有照片作为演示素材；GPS 仍是原始演示点位，不是替代照片的拍摄位置。',
        'original_count': len(originals),
        'original_sha256': {n: hashlib.sha256(p.read_bytes()).hexdigest() for n, p in originals.items()},
        'story_names': sorted(story),
        'mappings': mappings,
    }
    (ROOT.parent / 'docs/asset_replacements.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    representatives = {}
    aliases = {}
    for name in sorted(geo):
        source = mappings[name]['source']
        representative = representatives.setdefault(source, f'assets/thumbs/{name}')
        aliases[f'assets/thumbs/{name}'] = representative
    gpu_textures = sorted(set(aliases.values()) | {f'assets/photos/{n}' for n in story} | {'assets/earth_dark.jpg'})
    (ROOT / 'assets/texture_aliases.json').write_text(json.dumps(
        {'aliases': aliases, 'gpuTextures': gpu_textures, 'previewAssets': {f'assets/thumbs/{n}': f'assets/photos/{mappings[n]["source"]}' for n in geo}}, ensure_ascii=False, indent=2) + '\n')
    counts = {method: sum(m['method'] == method for m in mappings.values())
              for method in ['exact', 'same_capture_name', 'nearby_demo_replacement']}
    print(json.dumps({'originals': len(originals), 'photos': len(list(photos.glob('*.jpg'))),
                      'thumbs': len(list(thumbs.glob('*.jpg'))), 'mapping_counts': counts}, ensure_ascii=False))


if __name__ == '__main__':
    main()
