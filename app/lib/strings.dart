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
      _t('Mausrad dreht · Klick drückt · langer Klick: Zeiterfassung · Doppelklick: zurücksetzen',
          'Scroll turns · click presses · long click: time tracking · double click: reset');
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

  // Time tracking ----------------------------------------------------------------
  String get sectionDevice => _t('Gerät', 'Device');
  String get sectionTime => _t('Zeiterfassung', 'Time tracking');
  String get timeTracking => _t('Zeiterfassung …', 'Time tracking …');
  String get poweredBy => 'powered by meine-belichtungszeit.de';
  String get unnamed => _t('Unbenannt', 'Unnamed');
  String get newJob => _t('Neuer Job', 'New job');
  String get start => _t('Starten', 'Start');
  String get stop => _t('Stopp', 'Stop');
  String get noClock => _t('Keine Uhr läuft', 'No clock running');
  String unnamedHint(int count) => _t(
        count == 1 ? '1 unbenannter Job – bitte benennen' : '$count unbenannte Jobs – bitte benennen',
        count == 1 ? '1 unnamed job – please name it' : '$count unnamed jobs – please name them',
      );
  String get overview => _t('Übersicht', 'Overview');
  String get jobs => 'Jobs';
  String get entries => _t('Einträge', 'Entries');
  String get archive => _t('Archiv', 'Archive');
  String get search => _t('Suchen in Jobs, Kunden, Notizen', 'Search jobs, clients, notes');
  String get export => _t('CSV exportieren …', 'Export CSV …');
  String get week => _t('Woche', 'Week');
  String get month => _t('Monat', 'Month');
  String get range => _t('Zeitraum …', 'Period …');
  String get allTime => _t('Gesamt', 'All time');
  String get total => _t('Summe', 'Total');
  String get nothingRecorded => _t('In diesem Zeitraum wurde nichts erfasst.', 'Nothing recorded in this period.');
  String get noJobs => _t('Noch keine Jobs. Lege einen an oder starte einen am Gerät.', 'No jobs yet. Create one or start one on the device.');
  String get noArchived => _t('Keine archivierten Jobs.', 'No archived jobs.');
  String get noEntries => _t('Keine Einträge.', 'No entries.');
  String get noResults => _t('Nichts gefunden.', 'Nothing found.');
  String get name => _t('Name', 'Name');
  String get shortName => _t('Kürzel (max. 10 Zeichen, fürs Display)', 'Short name (max. 10 characters, for the display)');
  String get client => _t('Kunde', 'Client');
  String get color => _t('Farbe', 'Colour');
  String get lastUsed => _t('zuletzt', 'last used');
  String get edit => _t('Bearbeiten', 'Edit');
  String get archiveJob => _t('Archivieren', 'Archive');
  String get reactivate => _t('Reaktivieren', 'Reactivate');
  String get merge => _t('Zusammenführen …', 'Merge …');
  String mergeInto(String name) => _t('„$name“ zusammenführen mit', 'Merge "$name" into');
  String get mergeHint => _t(
        'Alle Einträge und Zuordnungen gehen auf den gewählten Job über; dieser Job wird gelöscht.',
        'All entries and assignments move to the chosen job; this job is deleted.',
      );
  String get cannotArchiveRunning => _t(
        'Die Uhr dieses Jobs läuft. Bitte erst stoppen.',
        'The clock of this job is running. Please stop it first.',
      );
  String get lightroomSources => _t('Lightroom-Zuordnung', 'Lightroom assignment');
  String get noSources => _t('Keine Sammlung und kein Ordner zugeordnet.', 'No collection or folder assigned.');
  String assignCurrent(String name) => _t('„$name“ zuordnen', 'Assign "$name"');
  String get collection => _t('Sammlung', 'Collection');
  String get folder => _t('Ordner', 'Folder');
  String get save => _t('Speichern', 'Save');
  String get cancel => _t('Abbrechen', 'Cancel');
  String get delete => _t('Löschen', 'Delete');
  String get add => _t('Eintrag hinzufügen', 'Add entry');
  String get allJobs => _t('Alle Jobs', 'All jobs');
  String get job => 'Job';
  String get from => _t('Start', 'Start');
  String get to => _t('Ende', 'End');
  String get note => _t('Notiz', 'Note');
  String get duration => _t('Dauer', 'Duration');
  String get running => _t('läuft', 'running');
  String get edited => _t('bearbeitet', 'edited');
  String get manual => _t('manuell', 'manual');
  String get endBeforeStart => _t('Das Ende muss nach dem Start liegen.', 'The end must be after the start.');
  String get rounding => _t('Rundung der Dauer', 'Rounding of durations');
  String get roundExact => _t('Sekundengenau', 'Exact to the second');
  String get roundMinute => _t('Auf Minuten', 'To minutes');
  String get roundQuarter => _t('Auf angefangene Viertelstunden', 'Up to started quarters of an hour');
  String get exportPeriod => _t('Zeitraum wie in der Übersicht gewählt', 'Period as chosen in the overview');
  String exported(String path) => _t('Exportiert nach $path', 'Exported to $path');
  List<String> get csvHeader =>
      language == Language.de ? const ['Job', 'Kunde', 'Start', 'Ende', 'Dauer', 'Notiz'] : const ['Job', 'Client', 'Start', 'End', 'Duration', 'Note'];
  String recoveryText(String job, String since) => _t(
        'Die Uhr für „$job“ lief noch, als Darkdial zuletzt beendet wurde ($since).',
        'The clock for "$job" was still running when Darkdial last quit ($since).',
      );
  String get recoveryContinue => _t('Weiterlaufen lassen', 'Keep running');
  String get recoveryStop => _t('Damals stoppen', 'Stop at that time');
  String get recoveryManual => _t('Ende festlegen …', 'Set the end …');
  String pauseText(String length) => _t(
        'Der Rechner hat $length pausiert, während die Uhr lief. Pause abziehen?',
        'The computer was asleep for $length while the clock was running. Deduct the pause?',
      );
  String get pauseDeduct => _t('Abziehen', 'Deduct');
  String get pauseKeep => _t('Behalten', 'Keep');

  String statusText(String key) => kStatusDefs.firstWhere((s) => s.key == key).label(language);
}
