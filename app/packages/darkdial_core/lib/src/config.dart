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

/// What a tap or a double tap does to the selected photo in the Library.
/// Doing the same again takes it back (flag, colour) or sets no stars.
enum LibraryMark {
  none,
  pick,
  reject,
  star1,
  star2,
  star3,
  star4,
  star5,
  red,
  yellow,
  green,
  blue,
  purple;

  /// Stars this action sets, 0 if it is not a rating.
  int get stars => index >= star1.index && index <= star5.index ? index - star1.index + 1 : 0;

  /// Lightroom's name of the colour label, null if it is not one.
  String? get colorLabel => index >= red.index ? name : null;

  static LibraryMark parse(Object? value, LibraryMark fallback) {
    for (final mark in values) {
      if (mark.name == value) return mark;
    }
    return fallback;
  }
}

/// Lightroom's colour labels in the order of the protocol (1 … 5).
const List<String> kColorLabels = ['red', 'yellow', 'green', 'blue', 'purple'];

/// The Library mode: while Lightroom shows the Library, the knob browses the
/// photos and taps on the display mark them.
class LibrarySettings {
  const LibrarySettings({
    this.enabled = true,
    this.tap = LibraryMark.pick,
    this.doubleTap = LibraryMark.star1,
    this.tapAdvances = false,
    this.doubleTapAdvances = false,
  });

  final bool enabled;
  final LibraryMark tap;
  final LibraryMark doubleTap;

  /// After the tap (double tap) has set its mark, go on to the next photo.
  /// Taking a mark back stays on the photo.
  final bool tapAdvances;
  final bool doubleTapAdvances;

  LibrarySettings copyWith({
    bool? enabled,
    LibraryMark? tap,
    LibraryMark? doubleTap,
    bool? tapAdvances,
    bool? doubleTapAdvances,
  }) =>
      LibrarySettings(
        enabled: enabled ?? this.enabled,
        tap: tap ?? this.tap,
        doubleTap: doubleTap ?? this.doubleTap,
        tapAdvances: tapAdvances ?? this.tapAdvances,
        doubleTapAdvances: doubleTapAdvances ?? this.doubleTapAdvances,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'tap': tap.name,
        'doubleTap': doubleTap.name,
        'tapAdvances': tapAdvances,
        'doubleTapAdvances': doubleTapAdvances,
      };

  factory LibrarySettings.fromJson(Object? json) {
    const defaults = LibrarySettings();
    if (json is! Map<String, dynamic>) return defaults;
    return LibrarySettings(
      enabled: json['enabled'] != false,
      tap: LibraryMark.parse(json['tap'], defaults.tap),
      doubleTap: LibraryMark.parse(json['doubleTap'], defaults.doubleTap),
      tapAdvances: json['tapAdvances'] == true,
      doubleTapAdvances: json['doubleTapAdvances'] == true,
    );
  }
}

/// The configuration edited in the app: every known slider in display order,
/// each enabled or not.
class AppConfig {
  const AppConfig({
    required this.language,
    required this.slots,
    this.followLightroom = true,
    this.library = const LibrarySettings(),
  });

  final Language language;
  final List<SlotSettings> slots;

  /// The device jumps to the slider that was just moved in Lightroom.
  final bool followLightroom;

  final LibrarySettings library;

  factory AppConfig.defaults([Language language = Language.de]) => AppConfig(
        language: language,
        slots: [for (final p in kParams) SlotSettings(paramId: p.id, enabled: p.defaultActive)],
      );

  /// Enabled sliders in order, capped at what the device can hold.
  List<SlotSettings> get activeSlots => slots.where((s) => s.enabled).take(maxSlots).toList();

  AppConfig copyWith({
    Language? language,
    List<SlotSettings>? slots,
    bool? followLightroom,
    LibrarySettings? library,
  }) =>
      AppConfig(
        language: language ?? this.language,
        slots: slots ?? this.slots,
        followLightroom: followLightroom ?? this.followLightroom,
        library: library ?? this.library,
      );

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
        'follow': followLightroom,
        'library': library.toJson(),
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
    return AppConfig(
      language: language,
      slots: slots,
      followLightroom: json['follow'] != false,
      library: LibrarySettings.fromJson(json['library']),
    );
  }
}
