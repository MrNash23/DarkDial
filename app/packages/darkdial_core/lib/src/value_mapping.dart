/// Conversion between Lightroom values and what the device shows. The device
/// knows no units: it gets a ring position and a ready-made text.
library;

import 'dart:math' as math;

import 'midi_codec.dart';
import 'param_def.dart';

/// Daylight sits at the top of the ring for raw white balance.
const double _kelvinCentre = 5500;

/// Range of a parameter for the current photo.
class ValueRange {
  const ValueRange(this.min, this.max);
  final double min;
  final double max;

  double clamp(double value) => value.clamp(min, max).toDouble();
}

/// Temperature is in Kelvin for raw photos and relative (−100 … 100) for
/// rendered files.
bool isKelvin(ParamDef param, ValueRange range) => param.format == ValueFormat.kelvin && range.min > 0;

/// Ring position 0 … 16383. For bipolar sliders the neutral value maps to
/// [positionCentre].
int ringPosition(ParamDef param, ValueRange range, double value) {
  final v = range.clamp(value);
  double fraction;
  if (range.max <= range.min) {
    fraction = 0;
  } else if (!param.bipolar) {
    fraction = (v - range.min) / (range.max - range.min);
  } else if (isKelvin(param, range)) {
    // Kelvin is perceived logarithmically.
    final centre = _kelvinCentre.clamp(range.min, range.max).toDouble();
    fraction = v < centre
        ? 0.5 * math.log(v / range.min) / math.log(centre / range.min)
        : 0.5 + 0.5 * math.log(v / centre) / math.log(range.max / centre);
  } else {
    final centre = (range.min < 0 && range.max > 0) ? 0.0 : (range.min + range.max) / 2;
    fraction = v < centre
        ? 0.5 * (v - range.min) / (centre - range.min)
        : 0.5 + 0.5 * (v - centre) / (range.max - centre);
  }
  if (fraction.isNaN) fraction = 0;
  return (fraction * positionMax).round().clamp(0, positionMax);
}

/// Text for the display, at most [maxValueTextBytes] ASCII characters.
String formatValue(ParamDef param, ValueRange range, double value) {
  if (isKelvin(param, range)) return '${value.round()}K';
  final text = value.abs().toStringAsFixed(param.decimals);
  final isZero = double.parse(text) == 0;
  if (param.format == ValueFormat.plain) return isZero ? text : (value < 0 ? '-$text' : text);
  if (isZero) return text;
  return value < 0 ? '-$text' : '+$text';
}

/// Change of one detent at the current [value].
double stepSize(ParamDef param, ValueRange range, double value, {double? stepOverride}) {
  if (stepOverride != null) return stepOverride;
  if (param.format == ValueFormat.kelvin) {
    if (!isKelvin(param, range)) return 1;
    // About 1 % per detent, in steps of 10 K: fine at 3000 K, quick at 20000 K.
    return math.max(10, (value * 0.01 / 10).round() * 10).toDouble();
  }
  return param.step;
}

/// New value after turning [detents] from [value]; snaps to the step grid so
/// values stay round. Kelvin steps vary with the value, so they snap to 10 K.
double applyDetents(
  ParamDef param,
  ValueRange range,
  double value,
  double detents, {
  double? stepOverride,
}) {
  final step = stepSize(param, range, value, stepOverride: stepOverride);
  final raw = value + detents * step;
  final grid = isKelvin(param, range) ? 10.0 : step;
  final snapped = (raw / grid).round() * grid;
  return range.clamp(snapped);
}
