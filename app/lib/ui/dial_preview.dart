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

    // The Library replaces the slot, as on the device.
    final library = state.library;
    final inLibrary = library.active && statusIcon == null && !inMenu;

    // The device is asked to turn its picture with the knob.
    final adjusting = state.displayAdjusting && !(model?.idle ?? false);
    final angle = state.displayAngle ?? 0;

    Widget content;
    if (adjusting) {
      content = _RotateContent(size: size, degrees: angle, language: s.language);
    } else if (inLibrary) {
      content = _LibraryContent(size: size, library: library, language: s.language);
    } else if (statusIcon != null) {
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

    // The preview stays upright even when the device's picture is turned:
    // the screen in front of the user is not turned.
    return _dial(context, content, slot, statusIcon != null || inLibrary || adjusting, ringColor, model, inMenu,
        menuInfo, clock, adjusting);
  }

  Widget _dial(
    BuildContext context,
    Widget content,
    SlotState? slot,
    bool noValueRing,
    Color ringColor,
    DeviceModel? model,
    bool inMenu,
    String? menuInfo,
    RunningClock? clock,
    bool adjusting,
  ) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          position: adjusting ? positionCentre : (slot == null || noValueRing ? null : slot.position),
          bipolar: slot?.slot.bipolar ?? true,
          color: adjusting ? accentColor : ringColor,
          marker: adjusting,
        ),
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            Positioned.fill(child: content),
            // Idle: the logo covers the display, as on the device.
            if (model != null && model.idle)
              Positioned.fill(
                child: ClipOval(
                  child: ColoredBox(
                    color: Colors.black,
                    child: Image.asset('assets/logo.png', key: const Key('preview-idle-logo')),
                  ),
                ),
              ),
            if (inMenu && !adjusting && menuInfo != null)
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
            if (inMenu && !adjusting)
              Positioned(
                top: size * 44 / 360,
                child: Text(
                  model!.menuTitle,
                  key: const Key('preview-menu-title'),
                  style: TextStyle(color: ringSelectColor, fontSize: size * 0.058),
                ),
              ),
            // The running time sits in the gap of the ring; in the menu it is shown big.
            if (clock != null && !inMenu && !adjusting)
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

/// The picture is being turned with the knob: title, hint and the angle.
class _RotateContent extends StatelessWidget {
  const _RotateContent({required this.size, required this.degrees, required this.language});

  final double size;
  final int degrees;
  final Language language;

  @override
  Widget build(BuildContext context) {
    final unit = size / 360;
    return Stack(
      key: const Key('preview-rotate'),
      alignment: Alignment.topCenter,
      children: [
        Positioned(
          top: 44 * unit,
          child: Text(
            kTimerTexts['rotate']![language.index],
            style: TextStyle(color: ringSelectColor, fontSize: size * 0.058),
          ),
        ),
        Positioned(
          top: 178 * unit,
          child: Text(
            kTimerTexts['rotateHint']![language.index],
            style: TextStyle(color: const Color(0xFFB8B8BE), fontSize: size * 0.058),
          ),
        ),
        Positioned(
          top: size * 0.635,
          child: Text(
            '$degrees',
            style: TextStyle(color: Colors.white, fontSize: size * 0.135, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }
}

/// Colour labels of Lightroom, index 1 … 5 as in the protocol.
const List<Color> _labelColors = [
  Colors.transparent,
  Color(0xFFFA3A31),
  Color(0xFFF8D32D),
  Color(0xFF7FE530),
  Color(0xFF5394FC),
  Color(0xFFAE72F9),
];

/// The Library screen: stars as dots, colour label, file name, flag.
class _LibraryContent extends StatelessWidget {
  const _LibraryContent({required this.size, required this.library, required this.language});

  final double size;
  final Library library;
  final Language language;

  @override
  Widget build(BuildContext context) {
    final unit = size / 360;
    final flag = library.flag > 0 ? 'picked' : (library.flag < 0 ? 'rejected' : null);
    return Stack(
      key: const Key('preview-library'),
      alignment: Alignment.topCenter,
      children: [
        Positioned(
          top: 44 * unit,
          child: Text(
            kTimerTexts['library']![language.index],
            style: TextStyle(color: ringSelectColor, fontSize: size * 0.058),
          ),
        ),
        Positioned(
          top: 100 * unit,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 5; i++)
                Container(
                  width: 26 * unit,
                  height: 26 * unit,
                  margin: EdgeInsets.symmetric(horizontal: 7 * unit),
                  decoration: BoxDecoration(
                    color: i < library.rating ? accentColor : ringTrackColor,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ),
        if (library.color >= 1 && library.color <= 5)
          Positioned(
            top: 144 * unit,
            child: Container(
              width: 186 * unit,
              height: 8 * unit,
              decoration: BoxDecoration(
                color: _labelColors[library.color],
                borderRadius: BorderRadius.circular(4 * unit),
              ),
            ),
          ),
        Positioned(
          top: size * 0.535,
          child: Text(
            library.name,
            style: TextStyle(color: const Color(0xFFB8B8BE), fontSize: size * 0.075, letterSpacing: 0.3),
          ),
        ),
        if (flag != null)
          Positioned(
            top: 236 * unit,
            child: Text(
              kTimerTexts[flag]![language.index],
              key: const Key('preview-library-flag'),
              style: TextStyle(
                color: library.flag > 0 ? Colors.white : const Color(0xFFE5484D),
                fontSize: size * 0.075,
              ),
            ),
          ),
      ],
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
  _RingPainter({required this.position, required this.bipolar, required this.color, this.marker = false});

  /// A short mark at the top instead of a value: where "up" is.
  final bool marker;

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
    if (marker) {
      canvas.drawArc(rect, -math.pi / 2 - 0.14, 0.28, false, paint);
      return;
    }
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
      old.position != position || old.bipolar != bipolar || old.color != color || old.marker != marker;
}
