import 'package:darkdial_core/darkdial_core.dart';

/// UI texts in the two languages of the short words. The app follows the
/// language chosen for the device.
class Strings {
  const Strings(this.language);
  final Language language;

  String _t(String de, String en) => language == Language.de ? de : en;

  String get configure => _t('Konfigurieren …', 'Configure …');
  String get launchAtLogin => _t('Beim Anmelden starten', 'Launch at login');
  String get quit => _t('Beenden', 'Quit');
  String get device => _t('Gerät', 'Device');
  String get lightroom => 'Lightroom';
  String get connected => _t('verbunden', 'connected');
  String get notConnected => _t('nicht verbunden', 'not connected');
  String get versionConflict => _t('Versionskonflikt', 'version conflict');
  String get simulator => _t('Simulator', 'simulator');
  String get activeControl => _t('Aktiver Regler', 'Active control');

  String get available => _t('Verfügbare Regler', 'Available controls');
  String get onDevice => _t('Auf dem Gerät', 'On the device');
  String get dragToReorder => _t('Ziehen zum Sortieren', 'Drag to reorder');
  String get noneEnabled => _t('Kein Regler aktiviert', 'No control enabled');
  String tooMany(int max) => _t('Das Gerät zeigt höchstens $max Regler', 'The device shows at most $max controls');
  String get preview => _t('Vorschau', 'Preview');
  String get previewHint =>
      _t('Mausrad dreht, Klick drückt den Knopf', 'Scroll wheel turns, click presses the knob');
  String get shortWord => _t('Kurzwort', 'Short word');
  String get icon => _t('Symbol', 'Icon');
  String get step => _t('Schrittweite', 'Step size');
  String get sensitivity => _t('Empfindlichkeit', 'Sensitivity');
  String get standard => _t('Standard', 'Default');
  String get resetSlot => _t('Zurücksetzen', 'Reset');
  String get languageLabel => _t('Sprache der Kurzwörter', 'Language of short words');
  String get sendToDevice => _t('Aufs Gerät übertragen', 'Send to device');
  String get sent => _t('Übertragen', 'Sent');
  String get sendFailed => _t('Übertragung fehlgeschlagen', 'Transfer failed');
  String get noDevice => _t('Kein Gerät verbunden', 'No device connected');

  String get info => _t('Info', 'About');
  String get app => 'App';
  String get firmware => 'Firmware';
  String get plugin => _t('Plugin', 'Plug-in');
  String get notInstalled => _t('nicht installiert', 'not installed');
  String get installPlugin => _t('Plugin installieren', 'Install plug-in');
  String get updatePlugin => _t('Plugin aktualisieren', 'Update plug-in');
  String get uninstall => _t('Deinstallieren', 'Uninstall');
  String get uninstallHint => _t(
        'Entfernt das Plugin aus Lightroom und den Autostart.',
        'Removes the plug-in from Lightroom and the login item.',
      );
  String get restartLightroom =>
      _t('Lightroom neu starten, damit das Plugin geladen wird.', 'Restart Lightroom to load the plug-in.');
  String get useSimulator => _t('Simulator statt Gerät verwenden', 'Use simulator instead of the device');
  String get conflictDevice => _t(
        'Die Firmware des Geräts passt nicht zu dieser App-Version.',
        'The device firmware does not match this app version.',
      );
  String get conflictPlugin => _t(
        'Das installierte Plugin passt nicht zu dieser App-Version. Bitte aktualisieren.',
        'The installed plug-in does not match this app version. Please update it.',
      );
  String get setupTitle => _t('Einrichtung', 'Setup');
  String get setupText => _t(
        'Darkdial braucht ein kleines Plugin in Lightroom Classic. Die App installiert es und startet '
            'künftig beim Anmelden.',
        'Darkdial needs a small plug-in in Lightroom Classic. The app installs it and will start at login.',
      );
  String get setupButton => _t('Einrichten', 'Set up');

  String statusText(String key) => kStatusDefs.firstWhere((s) => s.key == key).label(language);
}
