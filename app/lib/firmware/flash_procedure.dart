/// The whole firmware update over USB: find the device, send it into its
/// bootloader, write, verify, restart. No Flutter in here, so it also runs
/// from the command line (tool/flash.dart) and in a background isolate.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:darkdial_core/darkdial_core.dart';
import 'posix_serial.dart';

/// The serial port behind the flasher's [SerialLink].
class PosixSerialLink implements SerialLink {
  PosixSerialLink(this.port);
  final PosixSerialPort port;

  @override
  Future<void> write(List<int> bytes) async => port.write(bytes);

  @override
  Future<List<int>> read(Duration timeout) async {
    try {
      return port.read(timeout);
    } on SerialError catch (e) {
      throw FlashException(e.message, FlashFailure.connectionLost);
    }
  }

  @override
  Future<void> setSignals({required bool dtr, required bool rts}) async => port.setSignals(dtr: dtr, rts: rts);
}

/// Opening the port of a running Darkdial at 1200 baud and dropping DTR
/// restarts it into the bootloader (the Arduino core does that for us).
void _touch(String name) {
  try {
    final port = PosixSerialPort.open(name, baud: 1200, dtr: true);
    port.setSignals(dtr: false, rts: false);
    sleep(const Duration(milliseconds: 300));
    port.close();
  } on SerialError {
    // It restarts while we hold it; that is the point.
  }
}

/// Opens [name] and talks to the bootloader on it; null if it does not
/// answer within [within].
Future<(PosixSerialPort, EspFlasher)?> _openBootloader(String name, Duration within) async {
  final PosixSerialPort port;
  try {
    port = PosixSerialPort.open(name);
  } on SerialError {
    return null;
  }
  final flasher = EspFlasher(PosixSerialLink(port));
  try {
    await flasher.connect(within: within);
    return (port, flasher);
  } on FlashException {
    port.close();
    return null;
  }
}

/// Programs other than this one that have [port] open (a serial monitor, an
/// upload tool). They would take the bootloader's answers away.
Future<List<String>> _otherUsers(String port) async {
  try {
    final result = await Process.run('/usr/sbin/lsof', ['-F', 'pc', port]);
    final users = <String>[];
    String? pidLine;
    for (final line in (result.stdout as String).split('\n')) {
      if (line.startsWith('p')) pidLine = line.substring(1);
      if (line.startsWith('c') && pidLine != null && pidLine != '$pid') users.add(line.substring(1));
    }
    return users;
  } on Object {
    return const []; // no lsof: go ahead
  }
}

/// Updates the connected Darkdial with [merged] (an image written at 0; the
/// NVS partition is kept). Reports progress; throws [FlashException] when it
/// cannot finish.
Future<void> flashDevice(Uint8List merged, {void Function(FlashProgress progress)? onProgress}) async {
  onProgress?.call(const FlashProgress(FlashStage.connecting));
  var ports = PosixSerialPort.usbModemPorts();
  if (ports.isEmpty) throw FlashException('no Darkdial found on USB', FlashFailure.notFound);
  for (final name in ports) {
    final users = await _otherUsers(name);
    if (users.isNotEmpty) throw FlashException(users.toSet().join(', '), FlashFailure.portBusy);
  }

  // A device already in its bootloader (e.g. after an interrupted update)
  // answers right away; a running one is sent there first.
  (PosixSerialPort, EspFlasher)? open;
  for (final name in ports) {
    open = await _openBootloader(name, const Duration(milliseconds: 600));
    if (open != null) break;
  }
  if (open == null) {
    _touch(ports.first);
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    while (open == null && DateTime.now().isBefore(deadline)) {
      ports = PosixSerialPort.usbModemPorts();
      for (final name in ports) {
        open = await _openBootloader(name, const Duration(seconds: 2));
        if (open != null) break;
      }
      if (open == null) await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
  if (open == null) throw FlashException('the device did not start its bootloader', FlashFailure.noBootloader);

  final (port, flasher) = open;
  try {
    await flasher.flash(updateRegions(merged), onProgress: onProgress);
    onProgress?.call(const FlashProgress(FlashStage.restarting, 1));
    await flasher.restart();
  } finally {
    port.close();
  }
  onProgress?.call(const FlashProgress(FlashStage.done, 1));
}
