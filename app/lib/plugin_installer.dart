import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Installs the bundled Lightroom plugin into Lightroom's Modules folder,
/// where Lightroom loads it at startup without the Plug-in Manager.
class PluginInstaller {
  /// [modulesDir] overrides Lightroom's Modules folder (tests).
  PluginInstaller({Directory? modulesDir}) : _modulesDir = modulesDir; // ignore: prefer_initializing_formals

  final Directory? _modulesDir;

  static const String _assetPrefix = 'assets/plugin/';
  static const String _folderName = 'Darkdial.lrplugin';

  /// Lightroom's Modules folder for the current user.
  static Directory modulesDirectory() {
    if (Platform.isWindows) {
      return Directory(p.join(Platform.environment['APPDATA']!, 'Adobe', 'Lightroom', 'Modules'));
    }
    return Directory(p.join(
      Platform.environment['HOME']!,
      'Library',
      'Application Support',
      'Adobe',
      'Lightroom',
      'Modules',
    ));
  }

  Directory get _target => Directory(p.join((_modulesDir ?? modulesDirectory()).path, _folderName));

  Future<String> bundledVersion() async =>
      (await rootBundle.loadString('${_assetPrefix}version.txt')).trim();

  /// Version of the installed plugin, null if it is not installed.
  Future<String?> installedVersion() async {
    final file = File(p.join(_target.path, 'version.txt'));
    if (!await file.exists()) return null;
    return (await file.readAsString()).trim();
  }

  /// Copies the bundled plugin, replacing an installed one. Lightroom has to
  /// be restarted to load it.
  Future<void> install() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest.listAssets().where((a) => a.startsWith(_assetPrefix)).toList();
    if (assets.isEmpty) throw StateError('plugin is missing from the app bundle');
    final target = _target;
    if (await target.exists()) await target.delete(recursive: true);
    for (final asset in assets) {
      final file = File(p.join(target.path, asset.substring(_assetPrefix.length)));
      await file.parent.create(recursive: true);
      final data = await rootBundle.load(asset);
      await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    }
  }

  Future<void> uninstall() async {
    final target = _target;
    if (await target.exists()) await target.delete(recursive: true);
  }
}
