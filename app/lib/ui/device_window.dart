import 'package:darkdial_core/darkdial_core.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'config_window.dart';

/// Settings of the device itself: how its picture is oriented, the language
/// of the short words, whether it follows Lightroom, and sending the
/// configuration again.
class DeviceWindow extends StatefulWidget {
  const DeviceWindow({super.key, required this.controller});
  final AppController controller;

  @override
  State<DeviceWindow> createState() => _DeviceWindowState();
}

class _DeviceWindowState extends State<DeviceWindow> {
  String? _sendResult;

  AppController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (!c.ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        final s = c.strings;
        final small = Theme.of(context).textTheme.bodySmall;
        final hasDevice = c.state.device == DeviceLinkState.connected;
        return Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView(
                  key: const Key('device-settings'),
                  padding: const EdgeInsets.all(24),
                  children: [
                    SectionTitle(s.deviceDisplay),
                    _OrientationRow(controller: c),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(child: Text(s.languageLabel)),
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
                    ),
                    const Divider(height: 40),
                    SectionTitle(s.deviceBehaviour),
                    SwitchListTile(
                      key: const Key('follow-lightroom'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(s.followLightroom),
                      subtitle: Text(s.followLightroomHint, style: small),
                      value: c.config.followLightroom,
                      onChanged: (value) => c.setConfig(c.config.copyWith(followLightroom: value)),
                    ),
                    const Divider(height: 40),
                    SectionTitle(s.deviceTransfer),
                    Text(s.sendHint, style: small),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        OutlinedButton.icon(
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
                        Expanded(child: Text(hasDevice ? (_sendResult ?? '') : s.noDevice, style: small)),
                      ],
                    ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              SizedBox(
                width: 340,
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [PreviewSection(controller: c)],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The picture can be turned for a device that does not stand upright: a
/// button starts it, the knob of the device turns, saving ends it.
class _OrientationRow extends StatelessWidget {
  const _OrientationRow({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.strings;
    final angle = c.state.displayAngle;
    final small = Theme.of(context).textTheme.bodySmall;
    if (angle == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(child: Text(s.orientation)),
            Flexible(child: Text(s.rotateNeedsFirmware, style: small, textAlign: TextAlign.end)),
          ],
        ),
      );
    }
    if (c.state.displayAdjusting) {
      return Column(
        key: const Key('orientation-adjusting'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('${s.orientation}: ${s.orientationValue(angle)}')),
              TextButton(
                key: const Key('orientation-cancel'),
                onPressed: c.cancelDisplayRotation,
                child: Text(s.cancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('orientation-save'),
                onPressed: c.saveDisplayRotation,
                child: Text(s.save),
              ),
            ],
          ),
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(s.rotateHint, style: small)),
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: Text('${s.orientation}: ${s.orientationValue(angle)}', key: const Key('orientation-value'))),
        if (angle != 0)
          TextButton(
            key: const Key('orientation-upright'),
            onPressed: c.resetDisplayRotation,
            child: Text(s.rotateUpright),
          ),
        const SizedBox(width: 8),
        OutlinedButton(
          key: const Key('orientation-rotate'),
          onPressed: c.beginDisplayRotation,
          child: Text(s.rotateDisplay),
        ),
      ],
    );
  }
}
