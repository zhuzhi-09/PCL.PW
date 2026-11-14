import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 存档封面（Minecraft 的 icon.png 只有 64×64）的主色。
///
/// 大面积背景不拉伸封面，而是用这几个颜色做渐变；封面本身按像素风清晰显示。
class CoverPalette {
  const CoverPalette(this.colors);

  /// 按显眼程度排序的 3 个颜色（已压暗，适合做深色背景）
  final List<Color> colors;

  static final _cache = <String, Future<CoverPalette?>>{};

  /// 读取并计算主色；文件不存在或无法解码时返回 null。按路径 + 修改时间缓存
  static Future<CoverPalette?> of(String path) {
    final f = File(path);
    final stamp = f.existsSync() ? f.lastModifiedSync().millisecondsSinceEpoch : 0;
    return _cache.putIfAbsent('$path\u0000$stamp', () => _compute(f));
  }

  static Future<CoverPalette?> _compute(File f) async {
    try {
      if (!f.existsSync()) return null;
      final codec = await ui.instantiateImageCodec(await f.readAsBytes(), targetWidth: 32, targetHeight: 32);
      final image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (data == null) return null;
      return CoverPalette(extract(data.buffer.asUint8List()));
    } catch (_) {
      return null;
    }
  }

  /// 按颜色分桶统计，偏向饱和、不太暗的颜色，取差别足够大的 3 个
  static List<Color> extract(List<int> rgba) {
    final bins = <int, List<num>>{};
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      if (rgba[i + 3] < 128) continue;
      final key = ((r >> 5) << 6) | ((g >> 5) << 3) | (b >> 5);
      final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
      final w = 1 + (mx - mn) / 64 + (mx > 40 ? .5 : 0);
      final e = bins.putIfAbsent(key, () => [0, 0, 0, 0, 0.0]);
      e[0] = e[0] + r;
      e[1] = e[1] + g;
      e[2] = e[2] + b;
      e[3] = e[3] + 1;
      e[4] = e[4] + w;
    }
    final sorted = bins.values.toList()..sort((a, b) => b[4].compareTo(a[4]));
    final picked = <List<double>>[];
    for (final e in sorted) {
      final c = [e[0] / e[3], e[1] / e[3], e[2] / e[3]];
      final far = picked.every((p) {
        final dr = p[0] - c[0], dg = p[1] - c[1], db = p[2] - c[2];
        return math.sqrt(dr * dr + dg * dg + db * db) > 60;
      });
      if (far) picked.add(c);
      if (picked.length == 3) break;
    }
    if (picked.isEmpty) picked.add([40, 60, 45]);
    while (picked.length < 3) {
      picked.add(picked.first);
    }
    return [for (final c in picked) Color.fromARGB(255, (c[0] * .8).round(), (c[1] * .8).round(), (c[2] * .8).round())];
  }

  /// 由主色组成的纯色背景（界面默认不用渐变）
  Decoration background({BorderRadius? borderRadius}) =>
      BoxDecoration(borderRadius: borderRadius, color: colors[0]);
}

/// 封面背景：有封面时用取出的主色，否则用主题色压暗后的颜色；都是纯色
class CoverBackground extends StatelessWidget {
  const CoverBackground({super.key, required this.iconPath, this.borderRadius, this.child});

  final String? iconPath;
  final BorderRadius? borderRadius;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = CoverPalette([
      Color.lerp(scheme.primary, Colors.black, .55)!,
      Color.lerp(scheme.primaryContainer, Colors.black, .45)!,
      Color.lerp(scheme.surfaceContainerHigh, Colors.black, .35)!,
    ]);
    return FutureBuilder<CoverPalette?>(
      future: iconPath == null ? null : CoverPalette.of(iconPath!),
      builder: (context, snap) {
        final palette = snap.data ?? fallback;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          decoration: palette.background(borderRadius: borderRadius),
          clipBehavior: borderRadius == null ? Clip.none : Clip.antiAlias,
          child: child,
        );
      },
    );
  }
}

/// 封面小图：64×64 的存档图标按整数倍、最近邻放大，像素边缘清晰；没有封面时显示图标
class CoverThumb extends StatelessWidget {
  const CoverThumb({super.key, required this.iconPath, required this.size, this.radius = 10, this.modified});

  final String? iconPath;
  final double size;
  final double radius;

  /// 存档更新后封面会变，用修改时间让旧的图片缓存失效
  final DateTime? modified;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Container(
      width: size,
      height: size,
      color: scheme.primaryContainer,
      alignment: Alignment.center,
      child: Icon(Icons.landscape_outlined, size: size * .5, color: scheme.onPrimaryContainer),
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .35), blurRadius: 14, offset: const Offset(0, 6))],
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withValues(alpha: .14), width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: iconPath == null
          ? fallback
          : Image.file(
              File(iconPath!),
              key: ValueKey('$iconPath\u0000${modified?.millisecondsSinceEpoch}'),
              width: size,
              height: size,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.none,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}
