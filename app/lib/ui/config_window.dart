import 'package:darkdial_core/darkdial_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../strings.dart';
import 'dial_preview.dart';

/// The configuration window: available controls, order on the device,
/// preview, per-control settings and version info.
class ConfigWindow extends StatefulWidget {
  const ConfigWindow({super.key, required this.controller});
  final AppController controller;

  @override
  State<ConfigWindow> createState() => _ConfigWindowState();
}

class _ConfigWindowState extends State<ConfigWindow> {
  int? _selectedParam;
  String? _sendResult;

  AppController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (!c.ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        final s = c.strings;
        final active = c.config.slots.where((slot) => slot.enabled).toList();
        final selected = active.where((slot) => slot.paramId == _selectedParam).firstOrNull ??
            (active.isEmpty ? null : active[c.state.activeSlot.clamp(0, active.length - 1)]);
        return Scaffold(
          body: Column(
            children: [
              if (c.firstRun) _SetupBanner(controller: c),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 280, child: _AvailableList(controller: c)),
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: 260,
                      child: _ActiveList(
                        controller: c,
                        active: active,
                        selected: selected?.paramId,
                        onSelect: (id) => setState(() => _selectedParam = id),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: ListView(
                        key: const Key('config-details'),
                        padding: const EdgeInsets.all(20),
                        children: [
                          _PreviewSection(controller: c),
                          const SizedBox(height: 16),
                          _sendRow(s),
                          const SizedBox(height: 20),
                          if (selected != null) _SlotEditor(key: ValueKey(selected.paramId), controller: c, slot: selected),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _sendRow(Strings s) {
    final hasDevice = c.state.device == DeviceLinkState.connected;
    return Row(
      children: [
        FilledButton.icon(
          onPressed: hasDevice
              ? () async {
                  final ok = await c.sendToDevice();
                  if (mounted) setState(() => _sendResult = ok ? s.sent : s.sendFailed);
                }
              : null,
          icon: const Icon(Icons.upload, size: 18),
          label: Text(s.sendToDevice),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            hasDevice ? (_sendResult ?? '') : s.noDevice,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        SegmentedButton<Language>(
          segments: const [
            ButtonSegment(value: Language.de, label: Text('DE')),
            ButtonSegment(value: Language.en, label: Text('EN')),
          ],
          selected: {c.config.language},
          showSelectedIcon: false,
          onSelectionChanged: (value) => c.setLanguage(value.first),
        ),
      ],
    );
  }
}

String _slotTitle(SlotSettings slot, Language language) {
  final color = slot.param.colorLabel(language);
  final label = slot.param.label(language);
  return color == null ? label : '$label · $color';
}

Widget _slotIcon(SlotSettings slot, {double size = 28}) {
  final id = slot.icon ?? slot.param.icon;
  final color = slot.param.color;
  return Stack(
    alignment: Alignment.center,
    children: [
      ClipOval(
        child: Image.asset('assets/icons/icon_${id.toString().padLeft(2, '0')}.png', width: size, height: size),
      ),
      if (color != null)
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: size * 0.36,
            height: size * 0.36,
            decoration: BoxDecoration(
              color: Color(0xFF000000 | color),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.black, width: 1.5),
            ),
          ),
        ),
    ],
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 1.2)),
      );
}

/// All supported controls, grouped as in Lightroom, each with a switch.
class _AvailableList extends StatelessWidget {
  const _AvailableList({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final s = controller.strings;
    final language = controller.config.language;
    final byParam = {for (final slot in controller.config.slots) slot.paramId: slot};
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _SectionTitle(s.available)),
        for (final group in kParamGroups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(group.label(language), style: Theme.of(context).textTheme.titleSmall),
          ),
          for (final param in kParams.where((p) => p.group == group.key))
            SwitchListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              secondary: _slotIcon(byParam[param.id]!, size: 26),
              title: Text(_slotTitle(byParam[param.id]!, language)),
              value: byParam[param.id]!.enabled,
              onChanged: (value) => controller.setEnabled(param.id, value),
            ),
        ],
      ],
    );
  }
}

/// The enabled controls in device order; drag to reorder.
class _ActiveList extends StatelessWidget {
  const _ActiveList({
    required this.controller,
    required this.active,
    required this.selected,
    required this.onSelect,
  });

  final AppController controller;
  final List<SlotSettings> active;
  final int? selected;
  final void Function(int paramId) onSelect;

  @override
  Widget build(BuildContext context) {
    final s = controller.strings;
    final language = controller.config.language;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionTitle(s.onDevice),
              Text(
                active.isEmpty
                    ? s.noneEnabled
                    : (active.length > maxSlots ? s.tooMany(maxSlots) : s.dragToReorder),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            buildDefaultDragHandles: false,
            itemCount: active.length,
            onReorderItem: controller.reorderActive,
            itemBuilder: (context, index) {
              final slot = active[index];
              return ReorderableDragStartListener(
                key: ValueKey(slot.paramId),
                index: index,
                child: ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  selected: slot.paramId == selected,
                  leading: _slotIcon(slot, size: 26),
                  title: Text(slot.label ?? slot.param.label(language)),
                  subtitle: slot.param.color == null ? null : Text(slot.param.colorLabel(language)!),
                  trailing: const Icon(Icons.drag_handle, size: 18),
                  onTap: () => onSelect(slot.paramId),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PreviewSection extends StatelessWidget {
  const _PreviewSection({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final s = controller.strings;
    final model = controller.simulatorModel;
    Widget dial = DialPreview(controller: controller);
    if (model != null) {
      // With the simulator the preview is the device: wheel turns, click
      // presses, long press opens time tracking, double click resets a slot.
      dial = Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent && event.scrollDelta.dy != 0) {
            GestureBinding.instance.pointerSignalResolver.register(event, (_) {
              model.rotate(event.scrollDelta.dy > 0 ? 1 : -1);
            });
          }
        },
        child: GestureDetector(
          onTap: model.click,
          onDoubleTap: model.doubleTap,
          onLongPress: model.longPress,
          child: MouseRegion(cursor: SystemMouseCursors.click, child: dial),
        ),
      );
    }
    return Column(
      children: [
        Align(alignment: Alignment.centerLeft, child: _SectionTitle(s.preview)),
        dial,
        if (model != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(s.previewHint, style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }
}

/// Short word, icon, step size and sensitivity of one control.
class _SlotEditor extends StatefulWidget {
  const _SlotEditor({super.key, required this.controller, required this.slot});
  final AppController controller;
  final SlotSettings slot;

  @override
  State<_SlotEditor> createState() => _SlotEditorState();
}

class _SlotEditorState extends State<_SlotEditor> {
  late final TextEditingController _label = TextEditingController(text: widget.slot.label ?? '');
  late final TextEditingController _step = TextEditingController(text: _number(widget.slot.step));

  static String _number(double? value) {
    if (value == null) return '';
    return value == value.roundToDouble() ? value.toInt().toString() : value.toString();
  }

  @override
  void dispose() {
    _label.dispose();
    _step.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final s = c.strings;
    final slot = widget.slot;
    final language = c.config.language;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _SectionTitle(_slotTitle(slot, language))),
            TextButton(
              onPressed: () {
                _label.clear();
                _step.clear();
                c.updateSlot(SlotSettings(paramId: slot.paramId, enabled: slot.enabled));
              },
              child: Text(s.resetSlot),
            ),
          ],
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _label,
                maxLength: 10,
                decoration: InputDecoration(
                  labelText: s.shortWord,
                  hintText: slot.param.label(language),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (text) => c.updateSlot(slot.copyWith(label: () => text.trim().isEmpty ? null : text.trim())),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 140,
              child: TextField(
                controller: _step,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                decoration: InputDecoration(
                  labelText: s.step,
                  hintText: '${s.standard} ${_number(slot.param.step)}',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (text) {
                  final value = double.tryParse(text.replaceAll(',', '.'));
                  c.updateSlot(slot.copyWith(step: () => value != null && value > 0 ? value : null));
                },
              ),
            ),
          ],
        ),
        Row(
          children: [
            SizedBox(width: 120, child: Text(s.sensitivity)),
            Expanded(
              child: Slider(
                min: 0.25,
                max: 4,
                divisions: 15,
                value: slot.sensitivity.clamp(0.25, 4).toDouble(),
                label: '×${slot.sensitivity.toStringAsFixed(2)}',
                onChanged: (value) => c.updateSlot(slot.copyWith(sensitivity: value)),
              ),
            ),
            SizedBox(width: 48, child: Text('×${slot.sensitivity.toStringAsFixed(2)}')),
          ],
        ),
        const SizedBox(height: 4),
        Text(s.icon, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var id = 1; id <= 24; id++)
              InkWell(
                customBorder: const CircleBorder(),
                onTap: () => c.updateSlot(slot.copyWith(icon: () => id == slot.param.icon ? null : id)),
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: (slot.icon ?? slot.param.icon) == id ? accentColor : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: ClipOval(
                    child: Image.asset(
                      'assets/icons/icon_${id.toString().padLeft(2, '0')}.png',
                      width: 30,
                      height: 30,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Shown on the very first start: installs the plugin and the login item.
class _SetupBanner extends StatelessWidget {
  const _SetupBanner({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final s = controller.strings;
    return MaterialBanner(
      leading: Image.asset('assets/logo.png', width: 40, height: 40),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(s.setupTitle, style: Theme.of(context).textTheme.titleSmall),
          Text(s.setupText),
        ],
      ),
      actions: [
        TextButton(onPressed: controller.dismissSetup, child: const Icon(Icons.close, size: 18)),
        FilledButton(onPressed: controller.setUp, child: Text(s.setupButton)),
      ],
    );
  }
}
