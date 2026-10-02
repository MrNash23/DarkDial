// Runs a fake Lightroom plugin on the real ports, to try the app without
// Lightroom:
//
//     dart run darkdial_core:fake_lr
//
// Type `Exposure 1.5` to move a slider "with the mouse", `module library` or
// `module develop` to switch modules, `photo 2` / `photo none` to change the
// selection.
import 'dart:convert';
import 'dart:io';

import 'package:darkdial_core/src/fake_plugin.dart';

Future<void> main() async {
  final plugin = FakePlugin()
    ..onReceived = (message) {
      if (message['t'] != 'ping') stdout.writeln('<- ${jsonEncode(message)}');
    };
  try {
    await plugin.start();
  } on SocketException catch (e) {
    stderr.writeln('Cannot bind the plugin ports (is Lightroom running?): ${e.message}');
    exit(1);
  }
  stdout.writeln('Fake Lightroom plugin listening on ${plugin.toServicePort} / ${plugin.fromServicePort}.');
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length != 2) continue;
    final [name, argument] = parts;
    if (name == 'module') {
      plugin.userSwitchesModule(argument);
    } else if (name == 'photo') {
      plugin.userSelectsPhoto(int.tryParse(argument));
    } else if (plugin.values.containsKey(name) && double.tryParse(argument) != null) {
      plugin.userSets(name, double.parse(argument));
    } else {
      stdout.writeln('unknown: $line');
    }
  }
  await plugin.stop();
}
