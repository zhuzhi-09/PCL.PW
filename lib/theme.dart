import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

/// Pixel World 的默认品牌色。用户可以在个性化里改成任意颜色，配色仍按 MD3 生成。
const Color defaultThemeSeed = Color(0xFF2F6B4F);
const Color themeSeed = defaultThemeSeed;

/// 主色保留原色的饱和度；第二、第三色和中性色都用同一色相，
/// 避免 MD3 默认把第三色偏移成别的色系。错误色仍是红色。
DynamicScheme _md3Scheme(bool dark, Color seed) {
  final source = Hct.fromInt(seed.toARGB32());
  final hue = source.hue;
  final chroma = source.chroma;
  return DynamicScheme(
    sourceColorHct: source,
    variant: Variant.fidelity,
    isDark: dark,
    primaryPalette: TonalPalette.fromHct(source),
    secondaryPalette: TonalPalette.of(hue, _max(chroma - 32, chroma * 0.5)),
    tertiaryPalette: TonalPalette.of(hue, _max(chroma - 16, chroma * 0.7)),
    neutralPalette: TonalPalette.of(hue, chroma / 8),
    neutralVariantPalette: TonalPalette.of(hue, chroma / 8 + 4),
  );
}

double _max(double a, double b) => a > b ? a : b;

/// MD3 按钮形状：平时是药丸形（全圆角），按下时收成圆角矩形。
/// Material 会对形状变化做插值，所以按下时有一个圆角收缩的动画
final WidgetStateProperty<OutlinedBorder> md3ButtonShape = WidgetStateProperty.resolveWith(
  (states) => states.contains(WidgetState.pressed)
      ? const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12)))
      : const StadiumBorder(),
);

/// 圆形图标按钮按下时收成圆角方形
final WidgetStateProperty<OutlinedBorder> md3IconButtonShape = WidgetStateProperty.resolveWith(
  (states) => states.contains(WidgetState.pressed)
      ? const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12)))
      : const CircleBorder(),
);

const _buttonAnimation = Duration(milliseconds: 150);

ColorScheme md3ColorScheme(Brightness brightness, {Color seed = defaultThemeSeed}) {
  final s = _md3Scheme(brightness == Brightness.dark, seed);
  Color c(DynamicColor d) => Color(d.getArgb(s));
  return ColorScheme(
    brightness: brightness,
    primary: c(MaterialDynamicColors.primary),
    onPrimary: c(MaterialDynamicColors.onPrimary),
    primaryContainer: c(MaterialDynamicColors.primaryContainer),
    onPrimaryContainer: c(MaterialDynamicColors.onPrimaryContainer),
    primaryFixed: c(MaterialDynamicColors.primaryFixed),
    primaryFixedDim: c(MaterialDynamicColors.primaryFixedDim),
    onPrimaryFixed: c(MaterialDynamicColors.onPrimaryFixed),
    onPrimaryFixedVariant: c(MaterialDynamicColors.onPrimaryFixedVariant),
    secondary: c(MaterialDynamicColors.secondary),
    onSecondary: c(MaterialDynamicColors.onSecondary),
    secondaryContainer: c(MaterialDynamicColors.secondaryContainer),
    onSecondaryContainer: c(MaterialDynamicColors.onSecondaryContainer),
    secondaryFixed: c(MaterialDynamicColors.secondaryFixed),
    secondaryFixedDim: c(MaterialDynamicColors.secondaryFixedDim),
    onSecondaryFixed: c(MaterialDynamicColors.onSecondaryFixed),
    onSecondaryFixedVariant: c(MaterialDynamicColors.onSecondaryFixedVariant),
    tertiary: c(MaterialDynamicColors.tertiary),
    onTertiary: c(MaterialDynamicColors.onTertiary),
    tertiaryContainer: c(MaterialDynamicColors.tertiaryContainer),
    onTertiaryContainer: c(MaterialDynamicColors.onTertiaryContainer),
    tertiaryFixed: c(MaterialDynamicColors.tertiaryFixed),
    tertiaryFixedDim: c(MaterialDynamicColors.tertiaryFixedDim),
    onTertiaryFixed: c(MaterialDynamicColors.onTertiaryFixed),
    onTertiaryFixedVariant: c(MaterialDynamicColors.onTertiaryFixedVariant),
    error: c(MaterialDynamicColors.error),
    onError: c(MaterialDynamicColors.onError),
    errorContainer: c(MaterialDynamicColors.errorContainer),
    onErrorContainer: c(MaterialDynamicColors.onErrorContainer),
    surface: c(MaterialDynamicColors.surface),
    onSurface: c(MaterialDynamicColors.onSurface),
    surfaceDim: c(MaterialDynamicColors.surfaceDim),
    surfaceBright: c(MaterialDynamicColors.surfaceBright),
    surfaceContainerLowest: c(MaterialDynamicColors.surfaceContainerLowest),
    surfaceContainerLow: c(MaterialDynamicColors.surfaceContainerLow),
    surfaceContainer: c(MaterialDynamicColors.surfaceContainer),
    surfaceContainerHigh: c(MaterialDynamicColors.surfaceContainerHigh),
    surfaceContainerHighest: c(MaterialDynamicColors.surfaceContainerHighest),
    onSurfaceVariant: c(MaterialDynamicColors.onSurfaceVariant),
    outline: c(MaterialDynamicColors.outline),
    outlineVariant: c(MaterialDynamicColors.outlineVariant),
    shadow: c(MaterialDynamicColors.shadow),
    scrim: c(MaterialDynamicColors.scrim),
    inverseSurface: c(MaterialDynamicColors.inverseSurface),
    onInverseSurface: c(MaterialDynamicColors.inverseOnSurface),
    inversePrimary: c(MaterialDynamicColors.inversePrimary),
    surfaceTint: c(MaterialDynamicColors.surfaceTint),
  );
}

ThemeData buildTheme(Brightness brightness, {Color seed = defaultThemeSeed}) {
  final scheme = md3ColorScheme(brightness, seed: seed);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    // Windows 上 Segoe UI 没有中文字形，优先用微软雅黑
    fontFamily: 'Microsoft YaHei UI',
    fontFamilyFallback: const ['Microsoft YaHei', 'PingFang SC', 'Noto Sans CJK SC', 'sans-serif'],
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.standard,
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    // 手机横屏高度只有约 400：对话框标题小一号、上下边距收窄，内容区才放得下
    dialogTheme: DialogThemeData(
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
      titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: scheme.onSurface),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        shape: md3ButtonShape,
        animationDuration: _buttonAnimation,
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 20, vertical: 14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(shape: md3ButtonShape, animationDuration: _buttonAnimation),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(shape: md3ButtonShape, animationDuration: _buttonAnimation),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ButtonStyle(shape: md3ButtonShape, animationDuration: _buttonAnimation),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(shape: md3IconButtonShape, animationDuration: _buttonAnimation),
    ),
  );
}
