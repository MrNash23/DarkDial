// Flashes a merged firmware image from the command line, through the same
// code the app uses:
//
//   dart run tool/flash.dart <image.bin>
import 'dart:io';

import 'package:darkdial/firmware/flash_procedure.dart';
import 'package:darkdial_core/darkdial_core.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/flash.dart <merged-image.bin>');
    exit(2);
  }
  final image = File(args.first).readAsBytesSync();
  final started = DateTime.now();
  var shown = '';
  try {
    await flashDevice(image, onProgress: (p) {
      final line = '${p.stage.name} ${(p.fraction * 100).floor()}%';
      if (line != shown && (p.stage != FlashStage.writing || (p.fraction * 100).floor() % 10 == 0)) {
        shown = line;
        stdout.writeln('${DateTime.now().difference(started).inMilliseconds} ms  $line');
      }
    });
  } on FlashException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
}
