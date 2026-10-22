import 'package:flutter/material.dart';

import 'lcars.dart';

/// One stop on a guided tour: the part of the screen to light up (none for a centered note)
/// and what to say about it.
class TourStep {
  const TourStep(this.title, this.text, {this.target});
  final String title;
  final String text;
  final GlobalKey? target;
}

/// Dims the screen except one region and explains it, step by step. Sits over the whole
/// screen; [onNext] advances, [onClose] ends the tour.
class TourOverlay extends StatelessWidget {
  const TourOverlay({super.key, required this.steps, required this.index, required this.onNext, required this.onClose});
  final List<TourStep> steps;
  final int index;
  final VoidCallback onNext;
  final VoidCallback onClose;

  Rect? _holeIn(BuildContext context) {
    final target = steps[index].target?.currentContext?.findRenderObject();
    final me = context.findRenderObject();
    if (target is! RenderBox || me is! RenderBox || !target.hasSize || !target.attached) return null;
    final topLeft = me.globalToLocal(target.localToGlobal(Offset.zero));
    return (topLeft & target.size).inflate(4);
  }

  @override
  Widget build(BuildContext context) {
    final step = steps[index];
    final last = index == steps.length - 1;
    // The tour sits above the Scaffold, so it brings its own Material for text and ink.
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, box) {
          final hole = _holeIn(context);
          final card = Container(
            constraints: const BoxConstraints(maxWidth: 420),
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            decoration: BoxDecoration(
              color: LCARS.panel,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: LCARS.gold, width: 2),
              boxShadow: [BoxShadow(color: LCARS.black.withValues(alpha: 0.6), blurRadius: 16)],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(step.title.toUpperCase(), style: LCARS.font(18, color: LCARS.gold)),
                    ),
                    Text('${index + 1} / ${steps.length}', style: LCARS.font(12, color: LCARS.gray)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  step.text,
                  style: LCARS.font(16, weight: FontWeight.w500, color: LCARS.peach).copyWith(height: 1.3),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    if (!last)
                      Expanded(
                        child: LcarsButton('Skip tour', color: LCARS.gray, fill: false, height: 46, onPressed: onClose),
                      ),
                    if (!last) const SizedBox(width: 10),
                    Expanded(
                      child: LcarsButton(last ? 'Got it' : 'Next', color: LCARS.gold, height: 46, onPressed: last ? onClose : onNext),
                    ),
                  ],
                ),
              ],
            ),
          );
          // The note goes on the side of the screen away from the highlighted region.
          final below = hole == null ? null : hole.center.dy < box.maxHeight / 2;
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: () {},
                  child: CustomPaint(painter: _DimPainter(hole)),
                ),
              ),
              if (hole == null)
                Center(child: card)
              else if (below!)
                Positioned(
                  left: 0,
                  right: 0,
                  top: (hole.bottom + 12).clamp(0.0, box.maxHeight - 220),
                  child: Center(child: card),
                )
              else
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: (box.maxHeight - hole.top + 12).clamp(0.0, box.maxHeight - 220),
                  child: Center(child: card),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _DimPainter extends CustomPainter {
  _DimPainter(this.hole);
  final Rect? hole;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = const Color(0xCC000000);
    final all = Path()..addRect(Offset.zero & size);
    final h = hole;
    if (h == null) {
      canvas.drawPath(all, dim);
      return;
    }
    final cut = Path()..addRRect(RRect.fromRectAndRadius(h, const Radius.circular(12)));
    canvas.drawPath(Path.combine(PathOperation.difference, all, cut), dim);
    canvas.drawRRect(
      RRect.fromRectAndRadius(h, const Radius.circular(12)),
      Paint()
        ..color = LCARS.gold
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(_DimPainter old) => old.hole != hole;
}
