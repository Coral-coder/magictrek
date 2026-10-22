import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The LCARS look: black screens, rounded bars in orange, peach, lavender and blue, text at the
/// ends of bars, everything in condensed capitals.
class LCARS {
  static const orange = Color(0xFFFF9900);
  static const peach = Color(0xFFFFCC99);
  static const butterscotch = Color(0xFFFF9966);
  static const lavender = Color(0xFFCC99CC);
  static const violet = Color(0xFF9966CC);
  static const blue = Color(0xFF9999FF);
  static const skyBlue = Color(0xFF6688CC);
  static const ice = Color(0xFF99CCFF);
  static const gold = Color(0xFFFFCC66);
  static const red = Color(0xFFCC6666);
  static const alert = Color(0xFFFF3333);
  static const tan = Color(0xFFCC9966);
  static const green = Color(0xFF66CC99);
  static const gray = Color(0xFF666688);
  static const black = Colors.black;
  static const panel = Color(0xFF111118);

  static const palette = [orange, peach, lavender, blue, butterscotch, gold, skyBlue, violet];

  static Color forMana(String symbol) {
    switch (symbol) {
      case 'W':
        return peach;
      case 'U':
        return blue;
      case 'B':
        return violet;
      case 'R':
        return butterscotch;
      case 'G':
        return green;
      default:
        return gray;
    }
  }

  static TextStyle font(double size, {FontWeight weight = FontWeight.w700, Color color = peach}) =>
      TextStyle(fontSize: size, fontWeight: weight, color: color, fontFamily: 'sans-serif-condensed', fontFamilyFallback: const ['Arial Narrow', 'HelveticaNeue-CondensedBold', 'Roboto'], letterSpacing: 0.5, height: 1.1);
  static TextStyle get title => font(30, color: orange);
  static TextStyle get heading => font(20);
  static TextStyle get body => font(15, weight: FontWeight.w600);
  static TextStyle get label => font(12);
  static TextStyle get small => font(10);

  static ThemeData theme() => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: black,
        colorScheme: const ColorScheme.dark(primary: orange, secondary: lavender, surface: panel),
        useMaterial3: true,
        textTheme: TextTheme(bodyMedium: font(14, weight: FontWeight.w500), bodyLarge: font(16, weight: FontWeight.w500), titleLarge: font(22)),
        appBarTheme: const AppBarTheme(backgroundColor: black, foregroundColor: orange),
        dialogTheme: const DialogThemeData(backgroundColor: panel),
        bottomSheetTheme: const BottomSheetThemeData(backgroundColor: panel),
        snackBarTheme: SnackBarThemeData(backgroundColor: gold, contentTextStyle: font(13, color: black)),
      );
}

/// The classic LCARS elbow: a bar along the top that turns down the left side.
class ElbowPainter extends CustomPainter {
  ElbowPainter({required this.color, this.barHeight = 30, this.columnWidth = 64, this.outerRadius = 44, this.innerRadius = 14});
  final Color color;
  final double barHeight, columnWidth, outerRadius, innerRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Path()
      ..moveTo(outerRadius, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, barHeight)
      ..lineTo(columnWidth + innerRadius, barHeight)
      ..arcTo(Rect.fromCircle(center: Offset(columnWidth + innerRadius, barHeight + innerRadius), radius: innerRadius), -math.pi / 2, -math.pi / 2, false)
      ..lineTo(columnWidth, size.height)
      ..lineTo(0, size.height)
      ..lineTo(0, outerRadius)
      ..arcTo(Rect.fromCircle(center: Offset(outerRadius, outerRadius), radius: outerRadius), math.pi, math.pi / 2, false)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(ElbowPainter old) => old.color != color || old.barHeight != barHeight || old.columnWidth != columnWidth;
}

/// The screen frame: elbow in the corner, a column of colored blocks down the left, content on the right.
class LcarsFrame extends StatelessWidget {
  const LcarsFrame({super.key, required this.title, this.subtitle = '', this.color = LCARS.orange, this.blocks = const [LCARS.lavender, LCARS.blue, LCARS.peach, LCARS.butterscotch, LCARS.skyBlue], required this.child, this.onBack, this.actions = const []});
  final String title, subtitle;
  final Color color;
  final List<Color> blocks;
  final Widget child;
  final VoidCallback? onBack;
  final List<Widget> actions;

  static const column = 56.0;
  static const _heights = [60.0, 36.0, 90.0, 48.0, 70.0];

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: LCARS.black,
      body: Stack(
        children: [
          Positioned.fill(
            top: top + 4,
            left: 6,
            child: CustomPaint(painter: ElbowPainter(color: color, barHeight: 28, columnWidth: column, outerRadius: 40, innerRadius: 12)),
          ),
          Positioned(
            top: top + 4 + 28 + 14 + 40,
            left: 6,
            bottom: 0,
            width: column,
            child: Column(
              children: [
                for (var i = 0; i < blocks.length; i++) ...[
                  if (i < blocks.length - 1) Container(height: _heights[i % _heights.length], margin: const EdgeInsets.only(bottom: 4), color: blocks[i]) else Expanded(child: Container(margin: const EdgeInsets.only(bottom: 4), color: blocks[i])),
                ],
                Container(height: 40, decoration: BoxDecoration(color: color, borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(28)))),
              ],
            ),
          ),
          // Black gap between the elbow and the blocks.
          Positioned(top: top + 4 + 28 + 14, left: 6, width: column, height: 40, child: const ColoredBox(color: LCARS.black)),
          Positioned(top: top + 4 + 28 + 14 + 4, left: 6, width: column, height: 32, child: ColoredBox(color: blocks.first.withValues(alpha: 0.0))),
          Positioned(
            top: top + 4,
            left: 6,
            right: 0,
            height: 28,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const SizedBox(width: 48),
                if (onBack != null)
                  GestureDetector(onTap: onBack, behavior: HitTestBehavior.opaque, child: const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.chevron_left, color: LCARS.black, size: 26)))
                else
                  const SizedBox(width: 8),
                if (subtitle.isNotEmpty) Flexible(child: Text(subtitle.toUpperCase(), style: LCARS.font(11, color: LCARS.black), maxLines: 1, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                ...actions,
                Flexible(
                  flex: 3,
                  child: ColoredBox(color: LCARS.black, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text(title.toUpperCase(), style: LCARS.font(22, color: color), maxLines: 1, overflow: TextOverflow.ellipsis))),
                ),
                const SizedBox(width: 10),
              ],
            ),
          ),
          Positioned.fill(top: top + 4 + 28 + 10, left: 6 + column + 8, right: 8, child: child),
        ],
      ),
    );
  }
}

/// A rounded LCARS bar with a label at one end.
class LcarsBar extends StatelessWidget {
  const LcarsBar({super.key, this.text = '', this.color = LCARS.orange, this.height = 26});
  final String text;
  final Color color;
  final double height;
  @override
  Widget build(BuildContext context) => Container(
        height: height,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(height / 2)),
        child: Text(text.toUpperCase(), style: LCARS.font(12, color: LCARS.black), maxLines: 1, overflow: TextOverflow.ellipsis),
      );
}

/// A header line: a bar, a text label, a bar.
class LcarsHeader extends StatelessWidget {
  const LcarsHeader(this.title, {super.key, this.color = LCARS.orange});
  final String title;
  final Color color;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Container(width: 34, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6))),
          const SizedBox(width: 6),
          Flexible(child: Text(title.toUpperCase(), style: LCARS.font(18, color: color), maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 6),
          Expanded(child: Container(height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)))),
        ]),
      );
}

/// LCARS pill buttons: solid color, black condensed text.
class LcarsButton extends StatelessWidget {
  const LcarsButton(this.label, {super.key, required this.onPressed, this.color = LCARS.orange, this.height = 42, this.fill = true, this.icon, this.expand = true});
  final String label;
  final VoidCallback? onPressed;
  final Color color;
  final double height;
  final bool fill, expand;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final fg = fill ? LCARS.black : color;
    final child = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(height / 2),
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(color: fill ? color : color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(height / 2), border: fill ? null : Border.all(color: color, width: 2)),
          child: Row(mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
            if (icon != null) ...[Icon(icon, color: fg, size: 18), const SizedBox(width: 8)],
            Flexible(child: Text(label.toUpperCase(), style: LCARS.font(14, color: fg), maxLines: 1, overflow: TextOverflow.ellipsis)),
          ]),
        ),
      ),
    );
    return Opacity(opacity: enabled ? 1 : 0.4, child: child);
  }
}

/// A black panel outlined by a colored bar on the left, for content blocks.
class LcarsPanel extends StatelessWidget {
  const LcarsPanel({super.key, this.title = '', this.color = LCARS.lavender, required this.child});
  final String title;
  final Color color;
  final Widget child;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title.isNotEmpty) LcarsHeader(title, color: color),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 6, height: 24, margin: const EdgeInsets.only(top: 2), decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 8),
          Expanded(child: child),
        ]),
      ]);
}

/// A small numeric readout (life, cards, mana).
class LcarsReadout extends StatelessWidget {
  const LcarsReadout({super.key, required this.label, required this.value, this.color = LCARS.peach});
  final String label, value;
  final Color color;
  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: Text(value, key: ValueKey(value), style: LCARS.font(24, color: color))),
        Text(label.toUpperCase(), style: LCARS.font(9, color: LCARS.gray)),
      ]);
}

/// A sweeping scan line, for "working" states.
class ScanLine extends StatefulWidget {
  const ScanLine({super.key, this.color = LCARS.blue, this.width = 90});
  final Color color;
  final double width;
  @override
  State<ScanLine> createState() => _ScanLineState();
}

class _ScanLineState extends State<ScanLine> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.width,
        height: 4,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => Align(alignment: Alignment(_c.value * 2 - 1, 0), child: Container(width: 40, height: 4, decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(2)))),
        ),
      );
}

/// A starfield for backgrounds.
class Starfield extends StatelessWidget {
  const Starfield({super.key, this.count = 90, this.opacity = 0.6});
  final int count;
  final double opacity;
  @override
  Widget build(BuildContext context) => IgnorePointer(child: CustomPaint(painter: _StarPainter(count, opacity), size: Size.infinite));
}

class _StarPainter extends CustomPainter {
  _StarPainter(this.count, this.opacity);
  final int count;
  final double opacity;
  @override
  void paint(Canvas canvas, Size size) {
    final rng = math.Random(47);
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      final r = rng.nextDouble() * 1.4 + 0.3;
      paint.color = Colors.white.withValues(alpha: (0.35 + 0.5 * rng.nextDouble()) * opacity);
      canvas.drawCircle(Offset(rng.nextDouble() * size.width, rng.nextDouble() * size.height), r, paint);
    }
  }

  @override
  bool shouldRepaint(_StarPainter old) => old.count != count || old.opacity != opacity;
}

/// Mana symbols as colored pips.
class ManaCostPips extends StatelessWidget {
  const ManaCostPips(this.cost, {super.key, this.size = 14});
  final String cost;
  final double size;
  @override
  Widget build(BuildContext context) {
    final symbols = <String>[];
    var cur = '';
    var inside = false;
    for (final ch in cost.split('')) {
      if (ch == '{') {
        inside = true;
        cur = '';
      } else if (ch == '}') {
        inside = false;
        symbols.add(cur);
      } else if (inside) {
        cur += ch;
      }
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final s in symbols)
        Container(
          width: size,
          height: size,
          margin: const EdgeInsets.only(right: 2),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: LCARS.forMana(s), shape: BoxShape.circle),
          child: Text(s, style: TextStyle(fontSize: size * 0.62, fontWeight: FontWeight.w900, color: LCARS.black)),
        ),
    ]);
  }
}
