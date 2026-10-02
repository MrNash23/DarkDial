import 'package:darkdial_core/darkdial_core.dart';
import 'package:test/test.dart';

void main() {
  final exposure = paramByLr('Exposure')!;
  final contrast = paramByLr('Contrast')!;
  final sharpness = paramByLr('Sharpness')!;
  final temperature = paramByLr('Temperature')!;
  const raw = ValueRange(2000, 50000);
  const jpeg = ValueRange(-100, 100);

  group('ringPosition', () {
    test('bipolar: zero is the centre, ends are the ends', () {
      const range = ValueRange(-5, 5);
      expect(ringPosition(exposure, range, 0), positionCentre);
      expect(ringPosition(exposure, range, -5), 0);
      expect(ringPosition(exposure, range, 5), positionMax);
      expect(ringPosition(exposure, range, 99), positionMax, reason: 'clamped');
    });

    test('bipolar with asymmetric range keeps zero at the centre', () {
      const range = ValueRange(-50, 100);
      expect(ringPosition(contrast, range, 0), positionCentre);
      expect(ringPosition(contrast, range, -25), closeTo(positionMax * 0.25, 1));
      expect(ringPosition(contrast, range, 50), closeTo(positionMax * 0.75, 1));
    });

    test('unipolar is linear from the start', () {
      const range = ValueRange(0, 150);
      expect(ringPosition(sharpness, range, 0), 0);
      expect(ringPosition(sharpness, range, 75), closeTo(positionMax / 2, 1));
      expect(ringPosition(sharpness, range, 150), positionMax);
    });

    test('raw temperature puts daylight at the centre', () {
      expect(ringPosition(temperature, raw, 5500), positionCentre);
      expect(ringPosition(temperature, raw, 2000), 0);
      expect(ringPosition(temperature, raw, 50000), positionMax);
      expect(ringPosition(temperature, raw, 3300), lessThan(positionCentre));
    });

    test('JPEG temperature behaves like any bipolar slider', () {
      expect(ringPosition(temperature, jpeg, 0), positionCentre);
    });

    test('degenerate range does not throw', () {
      expect(ringPosition(contrast, const ValueRange(0, 0), 0), 0);
    });
  });

  group('formatValue', () {
    test('signed with decimals', () {
      const range = ValueRange(-5, 5);
      expect(formatValue(exposure, range, 1.35), '+1.35');
      expect(formatValue(exposure, range, -0.5), '-0.50');
      expect(formatValue(exposure, range, 0), '0.00');
      expect(formatValue(exposure, range, -0.001), '0.00', reason: 'no negative zero');
    });

    test('signed integer', () {
      expect(formatValue(contrast, jpeg, 12), '+12');
      expect(formatValue(contrast, jpeg, -100), '-100');
      expect(formatValue(contrast, jpeg, 0), '0');
    });

    test('plain', () {
      expect(formatValue(sharpness, const ValueRange(0, 150), 40), '40');
    });

    test('temperature: Kelvin for raw, signed for JPEG', () {
      expect(formatValue(temperature, raw, 5600), '5600K');
      expect(formatValue(temperature, raw, 50000), '50000K');
      expect(formatValue(temperature, jpeg, 15), '+15');
    });

    test('never exceeds what a Value message carries', () {
      for (final p in kParams) {
        for (final v in [p.min, p.max, 0.0]) {
          final text = formatValue(p, ValueRange(p.min, p.max), v);
          expect(text.length, lessThanOrEqualTo(maxValueTextBytes), reason: '${p.lr} $v');
        }
      }
    });
  });

  group('applyDetents', () {
    test('steps and clamps', () {
      const range = ValueRange(-5, 5);
      expect(applyDetents(exposure, range, 0, 1), closeTo(0.05, 1e-9));
      expect(applyDetents(exposure, range, 0, -3), closeTo(-0.15, 1e-9));
      expect(applyDetents(exposure, range, 4.98, 3), 5);
    });

    test('snaps an off-grid value onto the grid', () {
      expect(applyDetents(exposure, const ValueRange(-5, 5), 0.33, 1), closeTo(0.40, 1e-9));
    });

    test('step override wins', () {
      expect(applyDetents(contrast, jpeg, 0, 2, stepOverride: 5), 10);
    });

    test('raw temperature steps grow with the value', () {
      expect(applyDetents(temperature, raw, 3000, 1), 3030);
      expect(applyDetents(temperature, raw, 20000, 1), 20200);
      expect(applyDetents(temperature, jpeg, 0, 1), 1);
    });
  });

  group('AppConfig', () {
    test('defaults enable the 13 standard sliders in table order', () {
      final config = AppConfig.defaults();
      expect(config.slots, hasLength(45));
      expect(config.activeSlots, hasLength(13));
      expect(config.activeSlots.first.param.lr, 'Temperature');
      expect(config.deviceSlots()[2].label, 'Belichtung');
      expect(AppConfig.defaults(Language.en).deviceSlots()[2].label, 'Exposure');
    });

    test('JSON round-trip keeps order and overrides', () {
      final base = AppConfig.defaults(Language.en);
      final slots = base.slots.reversed.toList();
      slots[0] = slots[0].copyWith(enabled: true, label: () => 'Mag', step: () => 2.0, sensitivity: 0.5);
      final restored = AppConfig.fromJson(AppConfig(language: Language.en, slots: slots).toJson());
      expect(restored.language, Language.en);
      expect(restored.slots.first.paramId, slots.first.paramId);
      expect(restored.slots.first.label, 'Mag');
      expect(restored.slots.first.step, 2.0);
      expect(restored.slots.first.sensitivity, 0.5);
      expect(restored.slots, hasLength(45));
    });

    test('unknown sliders are dropped, missing ones appended disabled', () {
      final restored = AppConfig.fromJson({
        'language': 'de',
        'slots': [
          {'param': 999, 'enabled': true},
          {'param': 3, 'enabled': true},
          {'param': 3, 'enabled': false},
        ],
      });
      expect(restored.slots, hasLength(45));
      expect(restored.activeSlots.single.param.lr, 'Exposure');
    });

    test('HSL slots carry their colour, labels fit the device', () {
      final config = AppConfig.defaults();
      final all = AppConfig(
        language: Language.de,
        slots: [for (final s in config.slots) s.copyWith(enabled: true)],
      );
      final slots = all.deviceSlots();
      expect(slots, hasLength(45));
      expect(slots.firstWhere((s) => s.paramId == 32).color, 0xE5392F);
      for (final slot in slots) {
        expect(encodeMessage(slot).length, lessThanOrEqualTo(64), reason: slot.label);
      }
    });
  });
}
