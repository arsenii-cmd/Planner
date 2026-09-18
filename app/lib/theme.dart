import 'package:animations/animations.dart';
import 'package:flutter/material.dart';

/// Colours of the laptop's Serpantinum "Peach (old wallpaper)" theme.
abstract final class P {
  static const base = Color(0xFF140C0A);
  static const mantle = Color(0xFF231917);
  static const crust = Color(0xFF1A110F);
  static const surface0 = Color(0xFF271D1B);
  static const surface1 = Color(0xFF322825);
  static const surface2 = Color(0xFF3D3230);
  static const text = Color(0xFFF1DFDA);
  static const subtext0 = Color(0xFFD8C2BC);
  static const subtext1 = Color(0xFFA08C87);
  static const accent = Color(0xFFFFB5A0);
  static const accentDeep = Color(0xFF723523);
  static const sand = Color(0xFFD9C58D);
  static const rose = Color(0xFFE7BDB2);
  static const red = Color(0xFFFFB4AB);
}

const kFont = 'AdwaitaMono';
const kRadius = 14.0;

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: P.accent, brightness: Brightness.dark).copyWith(
    primary: P.accent,
    onPrimary: P.base,
    primaryContainer: P.accentDeep,
    onPrimaryContainer: P.text,
    secondary: P.rose,
    tertiary: P.sand,
    surface: P.base,
    onSurface: P.text,
    onSurfaceVariant: P.subtext1,
    surfaceContainerLowest: P.base,
    surfaceContainerLow: P.crust,
    surfaceContainer: P.mantle,
    surfaceContainerHigh: P.surface0,
    surfaceContainerHighest: P.surface1,
    outline: P.surface2,
    outlineVariant: P.surface1,
    error: P.red,
  );

  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius));
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, fontFamily: kFont);

  return base.copyWith(
    scaffoldBackgroundColor: P.base,
    textTheme: base.textTheme.apply(bodyColor: P.text, displayColor: P.text, fontFamily: kFont),
    appBarTheme: const AppBarTheme(
      backgroundColor: P.base,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontFamily: kFont, fontSize: 20, fontWeight: FontWeight.w700, color: P.text),
    ),
    cardTheme: CardThemeData(color: P.mantle, elevation: 0, margin: EdgeInsets.zero, shape: shape),
    dialogTheme: DialogThemeData(backgroundColor: P.mantle, shape: shape),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: P.mantle,
      showDragHandle: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: P.accent,
      foregroundColor: P.base,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: P.crust,
      indicatorColor: P.surface1,
      surfaceTintColor: Colors.transparent,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontFamily: kFont,
            fontSize: 12,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w400,
            color: s.contains(WidgetState.selected) ? P.accent : P.subtext1,
          )),
      iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? P.accent : P.subtext1)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: P.mantle,
      hintStyle: const TextStyle(color: P.subtext1),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(kRadius), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadius),
        borderSide: const BorderSide(color: P.accent, width: 1.5),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: P.surface1,
      contentTextStyle: const TextStyle(fontFamily: kFont, color: P.text),
      actionTextColor: P.accent,
      shape: shape,
    ),
    dividerTheme: const DividerThemeData(color: P.surface0, thickness: 1, space: 1),
    listTileTheme: const ListTileThemeData(iconColor: P.subtext0),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: SharedAxisPageTransitionsBuilder(
        transitionType: SharedAxisTransitionType.horizontal,
        fillColor: P.base,
      ),
    }),
  );
}

/// Fades and lifts a child in after [delay]; used for staggered list entrances.
class EnterAnimation extends StatelessWidget {
  const EnterAnimation({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) {
    final delay = (index * 45).clamp(0, 360);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 380 + delay),
      curve: Interval(delay / (380 + delay), 1, curve: Curves.easeOutCubic),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: child),
      ),
      child: child,
    );
  }
}

/// Small press-scale effect for tappable cards.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.onTap, this.onLongPress});

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
