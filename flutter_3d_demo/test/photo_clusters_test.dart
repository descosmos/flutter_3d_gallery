import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_3d_demo/gpu/photo_clusters.dart';
import 'package:flutter_3d_demo/story/photo_geo.dart';

void main() {
  test('根旗子的照片集合完整且没有重复', () {
    final roots = photoClusterRoots();
    final photos = roots.expand((c) => c.photos).toList();
    expect(photos.length, photoGeo.length);
    expect(photos.map((p) => p.key).toSet(), photoGeo.keys.toSet());
  });

  test('地点之间逐级展开，地点内部保持折叠，全部照片数量守恒', () {
    final leaves = <String>[];
    void visit(PhotoCluster cluster) {
      if (cluster.isLocation) {
        expect(cluster.children, isEmpty);
        leaves.addAll(cluster.photos.map((p) => p.key));
        return;
      }
      expect(cluster.children.length, greaterThan(1));
      expect(cluster.children.every((c) => c.count < cluster.count), isTrue);
      final members = cluster.children.expand((c) => c.photos).toList();
      expect(members.length, cluster.count);
      expect(
        members.map((p) => p.key).toSet(),
        cluster.photos.map((p) => p.key).toSet(),
      );
      for (final child in cluster.children) {
        visit(child);
      }
    }

    for (final root in photoClusterRoots()) {
      visit(root);
    }
    expect(leaves.toSet(), photoGeo.keys.toSet());
    expect(leaves.length, photoGeo.length);
  });

  test('90 张同坐标连拍只生成一个完整地点相册', () {
    final photos = List.generate(
      90,
      (i) => MapEntry('photo-$i.jpg', const GeoPoint(43, 86)),
    );
    final root = PhotoCluster('same-location', photos);
    expect(root.isLocation, isTrue);
    expect(root.children, isEmpty);
    expect(root.photos, photos);
    expect(root.count, 90);
  });

  test('跨网格边界的轻微 GPS 抖动仍是同一地点，远处地点保持独立', () {
    final photos = [
      const MapEntry('a', GeoPoint(43.9999, 85.9999)),
      const MapEntry('b', GeoPoint(44.0001, 86.0001)),
      const MapEntry('far', GeoPoint(44.003, 86.003)),
    ];
    final roots = photoClusterRoots(degrees: .02, photos: photos);
    final places = <PhotoCluster>[];
    void visit(PhotoCluster c) {
      if (c.isLocation) {
        places.add(c);
      } else {
        c.children.forEach(visit);
      }
    }

    roots.forEach(visit);
    expect(places.length, 2);
    expect(places.first.photos.map((p) => p.key), ['a', 'b']);
    expect(places.last.photos.single.key, 'far');
  });

  test('不能沿着连续步行轨迹把相隔数百米的照片链式合并', () {
    final photos = List.generate(
      10,
      (i) => MapEntry('walk-$i', GeoPoint(43 + i * .00025, 86)),
    );
    final root = PhotoCluster('walk', photos);
    expect(root.isLocation, isFalse);
    void visit(PhotoCluster c) {
      if (c.isLocation) {
        expect(c.count, lessThanOrEqualTo(2));
      } else {
        c.children.forEach(visit);
      }
    }

    visit(root);
  });

  test('单张旗子数量为 1；空分组不是有效旗子', () {
    final single = PhotoCluster('one', [
      const MapEntry('one.jpg', GeoPoint(0, 0)),
    ]);
    expect(single.count, 1);
    expect(single.isLeaf, isTrue);
    expect(() => PhotoCluster('empty', []), throwsArgumentError);
  });
}
