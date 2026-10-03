import 'package:darkdial_core/darkdial_core.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../firmware/firmware_updater.dart';
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
                    SectionTitle(s.deviceConnection),
                    Row(
                      children: [
                        SizedBox(width: 140, child: Text(s.connectionKind)),
                        Text(
                          c.state.device != DeviceLinkState.connected
                              ? s.notConnected
                              : (c.state.deviceWireless ? s.viaBluetooth : s.viaUsb),
                          key: const Key('connection-kind'),
                        ),
                      ],
                    ),
                    SwitchListTile(
                      key: const Key('use-bluetooth'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(s.useBluetooth),
                      subtitle: Text(s.useBluetoothHint, style: small),
                      value: c.config.useBluetooth,
                      onChanged: FirmwareUpdater.supported ? c.setUseBluetooth : null,
                    ),
                    const Divider(height: 40),
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
                    SectionTitle(s.deviceFirmware),
                    _FirmwareSection(controller: c),
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

/// Versions on the device and in the app, and writing the app's firmware to
/// the device.
class _FirmwareSection extends StatelessWidget {
  const _FirmwareSection({required this.controller});
  final AppController controller;

  Future<void> _confirmAndUpdate(BuildContext context) async {
    final s = controller.strings;
    final version = controller.firmware.bundled!.version;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.firmwareConfirmTitle),
        content: Text(s.firmwareConfirm(version)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.cancel)),
          FilledButton(
            key: const Key('firmware-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(s.firmwareStart),
          ),
        ],
      ),
    );
    if (ok == true) await controller.firmware.update();
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.strings;
    final small = Theme.of(context).textTheme.bodySmall;
    final bundled = c.firmware.bundled;
    final update = c.firmware.state.value;
    final onDevice = c.state.device == DeviceLinkState.connected ? c.state.firmwareVersion : null;

    Widget action;
    if (!FirmwareUpdater.supported) {
      action = Text(s.firmwareUnsupported, style: small);
    } else if (c.state.deviceWireless && !update.running) {
      action = Text(s.firmwareNeedsCable, key: const Key('firmware-needs-cable'), style: small);
    } else if (update.running) {
      final progress = update.progress!;
      action = Column(
        key: const Key('firmware-progress'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.firmwareStage(progress.stage)),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: progress.stage == FlashStage.writing ? progress.fraction : null),
        ],
      );
    } else {
      action = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (update.done) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(s.firmwareDone)),
          if (update.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(s.firmwareFailed(update.failure, update.error!), key: const Key('firmware-error'), style: small),
            ),
          OutlinedButton.icon(
            key: const Key('firmware-update'),
            onPressed: bundled == null ? null : () => _confirmAndUpdate(context),
            icon: const Icon(Icons.system_update_alt, size: 18),
            label: Text(update.error != null
                ? s.firmwareRetry
                : (c.firmwareOutdated || onDevice == null ? s.firmwareUpdate : s.firmwareReinstall)),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(width: 140, child: Text(s.firmwareOnDevice)),
            Text(onDevice ?? s.notConnected, key: const Key('firmware-device-version')),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            SizedBox(width: 140, child: Text(s.firmwareInApp)),
            Text(bundled?.version ?? s.firmwareNone, key: const Key('firmware-app-version')),
            if (c.firmwareOutdated)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(Icons.fiber_new_outlined, size: 18, color: Theme.of(context).colorScheme.primary),
              ),
          ],
        ),
        const SizedBox(height: 12),
        action,
      ],
    );
  }
}
