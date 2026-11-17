import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kit/kit.dart';
import 'package:material_ui/material_ui.dart';

/// DM Sans for text, Bricolage Grotesque for titles, JetBrains Mono for counts and dates
/// (DESIGN.md §4). Each has a Latin Extended file as its fallback, like the web app's.
const whirlSans = 'DMSans';
const whirlDisplay = 'BricolageGrotesque';
const whirlMono = 'JetBrainsMono';
const _fallback = {
  whirlSans: ['DMSansExt'],
  whirlDisplay: ['BricolageGrotesqueExt', 'DMSansExt'],
  whirlMono: ['JetBrainsMonoExt'],
};

/// The brand colours, the same in both themes (src/tokens.css).
abstract final class Brand {
  static const amber = Color(0xFFF5B82E);
  static const coral = Color(0xFFF2613F);
  static const teal = Color(0xFF2BB3A3);
  static const ink = Color(0xFF1F2430);
  static const cream = Color(0xFFFFF4E0);
}

/// Whirl's sizes that differ from kit's (src/tokens.css "Shape").
abstract final class WhirlRadii {
  static const double sm = 8, md = 14, lg = 22;
}

/// Whirl's colour roles on top of kit's tokens: the status trio, the wheel, the pointer and the
/// soft shadow light mode allows on floating things. Every colour in the app comes from here or
/// from [KitTokens]; values are src/tokens.css.
@immutable
class WhirlColors extends ThemeExtension<WhirlColors> {
  const WhirlColors({required this.pointer, required this.floatShadow});

  /// The wheel's pointer and hub, and the logo's: cream on dark, ink on light.
  final Color pointer;

  /// Sheets and the floating Spin button: none in dark mode (DESIGN.md §5).
  final List<BoxShadow> floatShadow;

  final Color idea = Brand.amber;
  final Color doing = Brand.coral;
  final Color completed = Brand.teal;

  /// Text on any status fill, and the wheel's labels.
  final Color onStatus = Brand.ink;

  /// The coral call to action (Spin, Start building).
  final Color cta = Brand.coral;

  Color status(String s) => switch (s) {
    'doing' => doing,
    'completed' => completed,
    _ => idea,
  };

  /// Slices cycle amber, coral, teal. If that would put two matching slices side by side where
  /// the circle closes, the last one takes coral.
  Color slice(int i, int total) {
    if (i == total - 1 && total % 3 == 1) return doing;
    return [idea, doing, completed][i % 3];
  }

  static const dark = WhirlColors(pointer: Brand.cream, floatShadow: []);
  static const light = WhirlColors(
    pointer: Brand.ink,
    floatShadow: [BoxShadow(color: Color(0x1F1F2430), blurRadius: 24, offset: Offset(0, 8))],
  );

  @override
  WhirlColors copyWith() => this;

  @override
  WhirlColors lerp(WhirlColors? other, double t) => t < 0.5 || other == null ? this : other;
}

Color _tint(Color on, Color c, [double a = 0.16]) => Color.lerp(on, c, a)!;

/// src/tokens.css as kit tokens. Kit's "sunken" surface is Whirl's `--surface-2` (inputs,
/// chips, the segmented track); its accent is coral, the primary action colour.
KitTokens whirlTokens(Brightness b) {
  if (b == Brightness.dark) {
    const surface = Color(0xFF1F2430);
    const danger = Color(0xFFFF7A6B);
    return KitTokens(
      bg: const Color(0xFF17191F),
      surface: surface,
      surfaceSunken: const Color(0xFF282E3B),
      surfaceHover: const Color(0xFF282E3B),
      border: const Color(0xFF343B4A),
      borderStrong: const Color(0xFF343B4A),
      text: const Color(0xFFF4EFE6),
      textMuted: const Color(0xFFA7A9B3),
      textFaint: const Color(0xFFA7A9B3),
      overlay: const Color(0x8C000000),
      accent: Brand.coral,
      onAccent: Brand.ink,
      accentText: Brand.amber,
      accentSoft: _tint(surface, Brand.coral),
      positive: Brand.teal,
      positiveSoft: _tint(surface, Brand.teal),
      negative: danger,
      negativeSoft: _tint(surface, danger),
      warningText: Brand.amber,
      warningSoft: _tint(surface, Brand.amber),
      shadow: const Color(0x00000000),
    );
  }
  const surface = Color(0xFFFFFFFF);
  const danger = Color(0xFFC2372A);
  return KitTokens(
    bg: const Color(0xFFFBF7F0),
    surface: surface,
    surfaceSunken: const Color(0xFFF3EDE3),
    surfaceHover: const Color(0xFFF3EDE3),
    border: const Color(0xFFE4DCCF),
    borderStrong: const Color(0xFFE4DCCF),
    text: Brand.ink,
    textMuted: const Color(0xFF5F6472),
    textFaint: const Color(0xFF5F6472),
    overlay: const Color(0x661F2430),
    accent: Brand.coral,
    onAccent: Brand.ink,
    accentText: const Color(0xFFC2410C),
    accentSoft: _tint(surface, Brand.coral, 0.12),
    positive: const Color(0xFF1D8A7E),
    positiveSoft: _tint(surface, Brand.teal, 0.12),
    negative: danger,
    negativeSoft: _tint(surface, danger, 0.1),
    warningText: const Color(0xFF8A5A00),
    warningSoft: _tint(surface, Brand.amber, 0.14),
    shadow: const Color(0x1F1F2430),
  );
}

TextStyle _withFallback(TextStyle s) => s.copyWith(fontFamilyFallback: _fallback[s.fontFamily] ?? _fallback[whirlSans]);

TextStyle _display(TextStyle s, {FontWeight weight = FontWeight.w700, double spacing = -0.02}) => s.copyWith(
  fontFamily: whirlDisplay,
  fontFamilyFallback: _fallback[whirlDisplay],
  fontWeight: weight,
  fontVariations: [FontVariation.weight(weight.value.toDouble())],
  letterSpacing: (s.fontSize ?? 16) * spacing,
);

ThemeData whirlTheme(Brightness b) {
  final t = whirlTokens(b);
  final colors = b == Brightness.dark ? WhirlColors.dark : WhirlColors.light;
  final base = buildKitTheme(t, b, extensions: [colors], fontFamily: whirlSans);
  final x = base.textTheme;
  final text = TextTheme(
    displayLarge: _display(x.displayLarge!),
    displayMedium: _display(x.displayMedium!),
    headlineMedium: _display(x.headlineMedium!),
    titleLarge: _display(x.titleLarge!.copyWith(fontSize: 20)),
    titleMedium: _withFallback(x.titleMedium!),
    titleSmall: _withFallback(x.titleSmall!),
    bodyLarge: _withFallback(x.bodyLarge!),
    bodyMedium: _withFallback(x.bodyMedium!),
    bodySmall: _withFallback(x.bodySmall!),
    labelLarge: _withFallback(x.labelLarge!),
    labelMedium: _withFallback(x.labelMedium!),
    labelSmall: _withFallback(x.labelSmall!),
  );
  OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(WhirlRadii.sm),
    borderSide: BorderSide(color: c, width: w),
  );
  return base.copyWith(
    textTheme: text,
    appBarTheme: base.appBarTheme.copyWith(titleTextStyle: text.titleLarge),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      fillColor: t.surfaceSunken,
      border: border(t.border),
      enabledBorder: border(t.border),
      focusedBorder: border(t.accentText, 2),
    ),
    bottomSheetTheme: base.bottomSheetTheme.copyWith(
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(WhirlRadii.lg))),
    ),
  );
}

extension WhirlContext on BuildContext {
  WhirlColors get whirl => Theme.of(this).extension<WhirlColors>()!;

  /// JetBrains Mono with tabular figures, for counts and dates.
  TextStyle mono(double size, {Color? color, FontWeight weight = FontWeight.w400}) => TextStyle(
    fontFamily: whirlMono,
    fontFamilyFallback: _fallback[whirlMono],
    fontSize: size,
    height: 1.3,
    color: color ?? kit.textMuted,
    fontWeight: weight,
    fontVariations: [FontVariation.weight(weight.value.toDouble())],
    fontFeatures: numFeatures,
  );

  /// Bricolage Grotesque, for titles.
  TextStyle display(double size, {Color? color, FontWeight weight = FontWeight.w700, double height = 1.2}) => _display(
    TextStyle(fontSize: size, height: height, color: color ?? kit.text),
    weight: weight,
  );
}

/// Theme is a phone setting, like the web app's (stored on the device, not synced).
final whirlThemeModeProvider = Provider<ThemeMode>((ref) => ref.watch(themeModeProvider));
