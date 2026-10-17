import 'package:fluent_ui/fluent_ui.dart';

/// Custom design tokens this app needs beyond standard Fluent theme tokens —
/// resolved automatically by [FluentApp.theme]/[FluentApp.darkTheme] and read
/// anywhere via `context.palette`.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.bg,
    required this.panel,
    required this.border,
    required this.text,
    required this.dim,
    required this.accent,
    required this.accentBg,
    required this.selectedBg,
    required this.statusBarBg,
    required this.statusBarText,
    required this.levelColor,
  });

  final Color bg;
  final Color panel;
  final Color border;
  final Color text;
  final Color dim;
  final Color accent;
  final Color accentBg;
  final Color selectedBg;
  final Color statusBarBg;
  final Color statusBarText;
  final Map<String, Color> levelColor;

  @override
  AppPalette copyWith({
    Color? bg,
    Color? panel,
    Color? border,
    Color? text,
    Color? dim,
    Color? accent,
    Color? accentBg,
    Color? selectedBg,
    Color? statusBarBg,
    Color? statusBarText,
    Map<String, Color>? levelColor,
  }) {
    return AppPalette(
      bg: bg ?? this.bg,
      panel: panel ?? this.panel,
      border: border ?? this.border,
      text: text ?? this.text,
      dim: dim ?? this.dim,
      accent: accent ?? this.accent,
      accentBg: accentBg ?? this.accentBg,
      selectedBg: selectedBg ?? this.selectedBg,
      statusBarBg: statusBarBg ?? this.statusBarBg,
      statusBarText: statusBarText ?? this.statusBarText,
      levelColor: levelColor ?? this.levelColor,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      bg: Color.lerp(bg, other.bg, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      border: Color.lerp(border, other.border, t)!,
      text: Color.lerp(text, other.text, t)!,
      dim: Color.lerp(dim, other.dim, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentBg: Color.lerp(accentBg, other.accentBg, t)!,
      selectedBg: Color.lerp(selectedBg, other.selectedBg, t)!,
      statusBarBg: Color.lerp(statusBarBg, other.statusBarBg, t)!,
      statusBarText: Color.lerp(statusBarText, other.statusBarText, t)!,
      levelColor: t < 0.5 ? levelColor : other.levelColor,
    );
  }
}

/// Which visual theme is active. Plain [ThemeMode] only distinguishes a
/// single light/dark pair, but this app offers two different dark looks
/// (VS Code "Dark Modern" and classic "Dark+"), so it needs its own choice.
enum AppThemeChoice { system, light, darkModern, vsDark }

/// VS Code's "Dark Modern" theme — flat, near-black chrome with a Microsoft-blue accent.
const kDarkModernPalette = AppPalette(
  bg: Color(0xFF1F1F1F),
  panel: Color(0xFF181818),
  border: Color(0xFF2B2B2B),
  text: Color(0xFFCCCCCC),
  dim: Color(0xFF9D9D9D),
  accent: Color(0xFF0078D4),
  accentBg: Color(0xFF0F3050),
  selectedBg: Color(0xFF2A2D2E),
  statusBarBg: Color(0xFF181818),
  statusBarText: Color(0xFF9D9D9D),
  levelColor: {
    'V': Color(0xFF9D9D9D),
    'D': Color(0xFF3B8EEA),
    'I': Color(0xFF23D18B),
    'W': Color(0xFFCCA700),
    'E': Color(0xFFF14C4C),
    'F': Color(0xFFD670D6),
    'S': Color(0xFF9D9D9D),
  },
);

/// Classic VS Code "Dark+" theme — original dark theme with signature purple-gray panels.
const kVsDarkPalette = AppPalette(
  bg: Color(0xFF1E1E1E),
  panel: Color(0xFF252526),
  border: Color(0xFF3C3C3C),
  text: Color(0xFFD4D4D4),
  dim: Color(0xFF969696),
  accent: Color(0xFF007ACC),
  accentBg: Color(0xFF04395E),
  selectedBg: Color(0xFF2A2D2E),
  statusBarBg: Color(0xFF007ACC),
  statusBarText: Color(0xFFFFFFFF),
  levelColor: {
    'V': Color(0xFF808080),
    'D': Color(0xFF569CD6),
    'I': Color(0xFFB5CEA8),
    'W': Color(0xFFCCA700),
    'E': Color(0xFFF14C4C),
    'F': Color(0xFFC586C0),
    'S': Color(0xFF808080),
  },
);

const kLightPalette = AppPalette(
  bg: Color(0xFFF6F7F9),
  panel: Color(0xFFFFFFFF),
  border: Color(0xFFDBE0E7),
  text: Color(0xFF1B2027),
  dim: Color(0xFF5B6472),
  accent: Color(0xFF0078D4),
  accentBg: Color(0xFFDFF0FA),
  selectedBg: Color(0xFFE8ECF2),
  statusBarBg: Color(0xFFFFFFFF),
  statusBarText: Color(0xFF5B6472),
  levelColor: {
    'V': Color(0xFF5B6472),
    'D': Color(0xFF1F6FB2),
    'I': Color(0xFF1E8E5A),
    'W': Color(0xFFAD6108),
    'E': Color(0xFFC5333D),
    'F': Color(0xFFC2185B),
    'S': Color(0xFF5B6472),
  },
);

FluentThemeData buildAppTheme(Brightness brightness, AppPalette palette) {
  return FluentThemeData(
    brightness: brightness,
    fontFamily: 'NotoSans',
    accentColor: AccentColor.swatch({'normal': palette.accent}),
    scaffoldBackgroundColor: palette.bg,
    cardColor: palette.panel,
    micaBackgroundColor: palette.bg,
    acrylicBackgroundColor: palette.panel,
    extensions: [palette],
  );
}

extension AppPaletteX on BuildContext {
  AppPalette get palette =>
      FluentTheme.of(this).extension<AppPalette>() ?? kDarkModernPalette;
}
