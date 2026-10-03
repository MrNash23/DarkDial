// Flashes the connected device through the app's background isolate. Only
// runs when asked to, with a merged image:
//
//   DARKDIAL_FLASH_IMAGE=../firmware/build/darkdial.ino.merged.bin flutter test test/hardware
import 'dart:io';

import 'package:darkdial/firmware/firmware_updater.dart';
import 'package:darkdial_core/darkdial_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final path = Platform.environment['DARKDIAL_FLASH_IMAGE'];
  test('flash the connected device', () async {
    final stages = <FlashStage>[];
    await FirmwareUpdater.flashInIsolate(File(path!).readAsBytesSync(), (p) {
      if (stages.isEmpty || stages.last != p.stage) stages.add(p.stage);
    });
    expect(stages, [
      FlashStage.connecting,
      FlashStage.erasing,
      FlashStage.writing,
      FlashStage.erasing,
      FlashStage.writing,
      FlashStage.verifying,
      FlashStage.restarting,
      FlashStage.done,
    ]);
  }, skip: path == null ? 'set DARKDIAL_FLASH_IMAGE to flash a device' : false, timeout: const Timeout(Duration(minutes: 3)));
}
