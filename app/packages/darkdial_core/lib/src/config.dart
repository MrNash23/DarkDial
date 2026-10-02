import 'midi_codec.dart';
import 'param_def.dart';
import 'params.g.dart';

final Map<int, ParamDef> _paramsById = {for (final p in kParams) p.id: p};
final Map<String, ParamDef> _paramsByLr = {for (final p in kParams) p.lr: p};

ParamDef? paramById(int id) => _paramsById[id];
ParamDef? paramByLr(String name) => _paramsByLr[name];

/// User settings of one slider.
class SlotSettings {
  const SlotSettings({
    required this.paramId,
    this.enabled = false,
    this.label,
    this.icon,
    this.step,
    this.sensitivity = 1.0,
  });

  final int paramId;
  final bool enabled;

  /// Overrides, null = use the parameter's default.
  final String? label;
  final int? icon;
  final double? step;

  /// Multiplier on the detents coming from the device.
  final double sensitivity;

  ParamDef get param => _paramsById[paramId]!;

  SlotSettings copyWith({
    bool? enabled,
    String? Function()? label,
    int? Function()? icon,
    double? Function()? step,
    double? sensitivity,
  }) =>
      SlotSettings(
        paramId: paramId,
        enabled: enabled ?? this.enabled,
        label: label != null ? label() : this.label,
        icon: icon != null ? icon() : this.icon,
        step: step != null ? step() : this.step,
        sensitivity: sensitivity ?? this.sensitivity,
      );

  Map<String, dynamic> toJson() => {
        'param': paramId,
        'enabled': enabled,
        if (label != null) 'label': label,
        if (icon != null) 'icon': icon,
        if (step != null) 'step': step,
        if (sensitivity != 1.0) 'sensitivity': sensitivity,
      };

  static SlotSettings? fromJson(Map<String, dynamic> json) {
    final id = json['param'];
    if (id is! int || !_paramsById.containsKey(id)) return null;
    return SlotSettings(
      paramId: id,
      enabled: json['enabled'] == true,
      label: json['label'] as String?,
      icon: json['icon'] as int?,
      step: (json['step'] as num?)?.toDouble(),
      sensitivity: (json['sensitivity'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

/// The configuration edited in the app: every known slider in display order,
/// each enabled or not.
class AppConfig {
  const AppConfig({required this.language, required this.slots});

  final Language language;
  final List<SlotSettings> slots;

  factory AppConfig.defaults([Language language = Language.de]) => AppConfig(
        language: language,
        slots: [for (final p in kParams) SlotSettings(paramId: p.id, enabled: p.defaultActive)],
      );

  /// Enabled sliders in order, capped at what the device can hold.
  List<SlotSettings> get activeSlots => slots.where((s) => s.enabled).take(maxSlots).toList();

  AppConfig copyWith({Language? language, List<SlotSettings>? slots}) =>
      AppConfig(language: language ?? this.language, slots: slots ?? this.slots);

  /// What is sent to the device for the active slots.
  List<ConfigSlot> deviceSlots() {
    final active = activeSlots;
    return [
      for (var i = 0; i < active.length; i++)
        ConfigSlot(
          index: i,
          paramId: active[i].paramId,
          iconId: active[i].icon ?? active[i].param.icon,
          bipolar: active[i].param.bipolar,
          color: active[i].param.color ?? 0,
          label: active[i].label ?? active[i].param.label(language),
        ),
    ];
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'language': language.name,
        'slots': [for (final s in slots) s.toJson()],
      };

  /// Reads a stored configuration. Sliders unknown to this version are
  /// dropped, sliders missing in the file are appended disabled, so files
  /// survive up- and downgrades.
  factory AppConfig.fromJson(Map<String, dynamic> json) {
    final language = json['language'] == 'en' ? Language.en : Language.de;
    final slots = <SlotSettings>[];
    final seen = <int>{};
    final stored = json['slots'];
    if (stored is List) {
      for (final entry in stored) {
        if (entry is! Map<String, dynamic>) continue;
        final slot = SlotSettings.fromJson(entry);
        if (slot != null && seen.add(slot.paramId)) slots.add(slot);
      }
    }
    for (final p in kParams) {
      if (!seen.contains(p.id)) slots.add(SlotSettings(paramId: p.id));
    }
    return AppConfig(language: language, slots: slots);
  }
}
