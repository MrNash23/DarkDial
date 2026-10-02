/// How a value is written on the display.
enum ValueFormat {
  /// `+12`, `-0.35`, `0`
  signed,

  /// `25`
  plain,

  /// `5600K` for raw photos; JPEGs have a relative range and use [signed].
  kelvin,
}

/// One Develop slider Darkdial can control. Generated from
/// `protocol/params.json` into `params.g.dart`.
class ParamDef {
  const ParamDef({
    required this.id,
    required this.lr,
    required this.group,
    required this.de,
    required this.en,
    required this.bipolar,
    required this.icon,
    required this.min,
    required this.max,
    required this.step,
    required this.decimals,
    required this.format,
    required this.defaultActive,
    required this.color,
    required this.colorDe,
    required this.colorEn,
  });

  /// Protocol ID, stable across versions.
  final int id;

  /// Name in the Lightroom SDK, e.g. `Exposure`.
  final String lr;
  final String group;
  final String de;
  final String en;
  final bool bipolar;
  final int icon;

  /// Fallback range until the plugin reports the real one for the photo.
  final double min;
  final double max;

  /// Change per detent at sensitivity 1.
  final double step;
  final int decimals;
  final ValueFormat format;
  final bool defaultActive;

  /// `0xRRGGBB` of the HSL colour dot, null for all other sliders.
  final int? color;
  final String? colorDe;
  final String? colorEn;

  String label(Language language) => language == Language.de ? de : en;

  String? colorLabel(Language language) => language == Language.de ? colorDe : colorEn;
}

class ParamGroup {
  const ParamGroup(this.key, this.de, this.en);
  final String key;
  final String de;
  final String en;

  String label(Language language) => language == Language.de ? de : en;
}

class StatusDef {
  const StatusDef(this.key, this.icon, this.de, this.en);
  final String key;
  final int icon;
  final String de;
  final String en;

  String label(Language language) => language == Language.de ? de : en;
}

enum Language { de, en }
