import 'dart:math' as math;

import 'package:darkdial_core/darkdial_core.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';

/// Geometry and colours shared with the firmware UI
/// (firmware/darkdial/src/ui.cpp); keep both in sync.
const double ringGapDegrees = 60; // open at the bottom
const double ringSweepDegrees = 360 - ringGapDegrees;
const Color ringTrackColor = Color(0xFF26262B);
const Color ringSelectColor = Color(0xFF8A8A90);
const Color accentColor = Color(0xFFFF9F0A);

/// What the round display shows right now.
class DialPreview extends StatelessWidget {
  const DialPreview({super.key, required this.controller, this.size = 260});

  final AppController controller;
  final double size;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final s = controller.strings;

    // Same priorities as the firmware: status screens replace the slot.
    int? statusIcon;
    String? statusLabel;
    if (state.lightroomConnected && !state.photoSelected) {
      statusIcon = 26;
      statusLabel = s.statusText('noPhoto');
    }

    // Time tracking menu and confirmations live on the device only; the
    // simulator's model has them, a real device shows them itself.
    final model = controller.simulatorModel;
    final clock = controller.tracker.running;
    String menuTime = '';
    var menuHighlighted = false;

    /// Help text of the menu's last line, shown small and wrapped.
    String? menuInfo;
    if (model != null && model.notice != null) {
      final notice = model.notice!;
      statusIcon = notice.code == TimerResult.started ? kTimerIcons['stopwatch'] : kTimerIcons['stop'];
      final texts = notice.code == TimerResult.started
          ? kTimerTexts['started']!
          : (notice.code == TimerResult.stopped ? kTimerTexts['stopped']! : [notice.text, notice.text]);
      statusLabel = texts[s.language.index];
    } else if (model != null && model.menuOpen) {
      if (model.menu.isEmpty) {
        // Just opened: the page is on its way.
        statusIcon = kTimerIcons['stopwatch'];
        statusLabel = '';
      } else {
        final item = model.menu[model.menuIndex];
        statusIcon = item.icon;
        statusLabel = item.submenu ? '${item.label} »' : item.label;
        if (item.info) menuInfo = kTimerTexts['noClient']![s.language.index];
        menuHighlighted = item.highlighted;
        if (item.running && clock != null) menuTime = formatClock(clock.elapsed(DateTime.now().toUtc()));
      }
    }
    final inMenu = model != null && model.menuOpen && model.notice == null;

    final slot = state.slots.isEmpty ? null : state.slots[state.activeSlot];
    final live = state.lightroomConnected && slot?.value != null;
    final slotColor = slot != null && slot.slot.color != 0 ? Color(0xFF000000 | slot.slot.color) : null;
    final ringColor = !live
        ? ringTrackColor
        : (state.editing ? (slotColor ?? accentColor) : ringSelectColor);

    final iconSize = size * 112 / 360;
    final dot = controller.hslDot;

    Widget content;
    if (statusIcon != null) {
      content = _Content(
        size: size,
        icon: Image.asset('assets/icons/icon_$statusIcon.png', width: iconSize, height: iconSize),
        label: statusLabel!,
        value: menuTime,
        labelColor: menuHighlighted ? accentColor : null,
      );
    } else if (slot == null) {
      content = const SizedBox.shrink();
    } else {
      content = _Content(
        size: size,
        icon: Stack(
          children: [
            Image.asset(
              'assets/icons/icon_${slot.slot.iconId.toString().padLeft(2, '0')}.png',
              width: iconSize,
              height: iconSize,
              filterQuality: FilterQuality.medium,
            ),
            if (slotColor != null)
              Positioned(
                left: (dot.x - dot.radius) * iconSize,
                top: (dot.y - dot.radius) * iconSize,
                child: Container(
                  width: dot.radius * 2 * iconSize,
                  height: dot.radius * 2 * iconSize,
                  decoration: BoxDecoration(color: slotColor, shape: BoxShape.circle),
                ),
              ),
          ],
        ),
        label: slot.slot.label,
        value: slot.text,
      );
    }

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          position: slot == null || statusIcon != null ? null : slot.position,
          bipolar: slot?.slot.bipolar ?? true,
          color: ringColor,
        ),
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            Positioned.fill(child: content),
            if (inMenu && menuInfo != null)
              Positioned(
                top: size * 178 / 360,
                width: size * 250 / 360,
                child: Text(
                  menuInfo,
                  key: const Key('preview-menu-info'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: const Color(0xFFB8B8BE), fontSize: size * 0.058, height: 1.2),
                ),
              ),
            if (inMenu)
              Positioned(
                top: size * 30 / 360,
                child: Text(
                  model.menuTitle,
                  key: const Key('preview-menu-title'),
                  style: TextStyle(color: ringSelectColor, fontSize: size * 0.058),
                ),
              ),
            // The running time sits in the gap of the ring; in the menu it is shown big.
            if (clock != null && !inMenu)
              Positioned(
                bottom: size * 10 / 360,
                child: ValueListenableBuilder<int>(
                  valueListenable: controller.clockTick,
                  builder: (context, _, _) => Text(
                    formatClock(clock.elapsed(DateTime.now().toUtc())),
                    key: const Key('preview-gap-time'),
                    style: TextStyle(
                      color: const Color(0xFFB8B8BE),
                      fontSize: size * 0.062,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({
    required this.size,
    required this.icon,
    required this.label,
    required this.value,
    this.labelColor,
  });

  final double size;
  final Widget icon;
  final String label;
  final String value;
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.topCenter,
      children: [
        Positioned(top: size * 0.17, child: icon),
        Positioned(
          top: size * 0.535,
          child: Text(
            label,
            style: TextStyle(color: labelColor ?? const Color(0xFFB8B8BE), fontSize: size * 0.075, letterSpacing: 0.3),
          ),
        ),
        Positioned(
          top: size * 0.635,
          child: Text(
            value,
            style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.135,
              fontWeight: FontWeight.w500,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.position, required this.bipolar, required this.color});

  /// Ring position 0 … 16383, null = track only.
  final int? position;
  final bool bipolar;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    canvas.drawCircle(centre, size.width / 2, Paint()..color = Colors.black);

    final stroke = size.width * 14 / 360;
    final rect = Rect.fromCircle(center: centre, radius: size.width / 2 - stroke / 2 - size.width * 6 / 360);
    // Canvas angles run clockwise from 3 o'clock; the gap is centred at 6 o'clock.
    const start = (90 + ringGapDegrees / 2) * math.pi / 180;
    const sweep = ringSweepDegrees * math.pi / 180;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, start, sweep, false, paint..color = ringTrackColor);
    final position = this.position;
    if (position == null) return;
    final fraction = position / positionMax;
    paint.color = color;
    if (bipolar) {
      // From the top to the left or right.
      final delta = (fraction - 0.5) * sweep;
      if (delta.abs() < 0.01) {
        canvas.drawArc(rect, -math.pi / 2 - 0.005, 0.01, false, paint);
      } else {
        canvas.drawArc(rect, -math.pi / 2, delta, false, paint);
      }
    } else {
      canvas.drawArc(rect, start, math.max(0.01, fraction * sweep), false, paint);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.position != position || old.bipolar != bipolar || old.color != color;
}
