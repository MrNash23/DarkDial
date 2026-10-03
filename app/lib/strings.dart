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
      _t('Mausrad dreht · Klick tippt · Doppelklick doppeltippt · Rechtsklick drückt den Knopf · '
              'langer Klick: Zeiterfassung',
          'Scroll turns · click taps · double click double-taps · right click presses the knob · '
              'long click: time tracking');
  String get shortWord => _t('Kurzwort', 'Short word');
  String get icon => _t('Symbol', 'Icon');
  String get step => _t('Schrittweite', 'Step size');
  String get sensitivity => _t('Empfindlichkeit', 'Sensitivity');
  String get standard => _t('Standard', 'Default');
  String get resetSlot => _t('Zurücksetzen', 'Reset');
  String get languageLabel => _t('Sprache der Kurzwörter', 'Language of short words');
  String get followLightroom => _t(
        'Zum Regler springen, der in Lightroom bewegt wird',
        'Jump to the slider that is moved in Lightroom',
      );
  String get deviceFirmware => 'Firmware';
  String get firmwareOnDevice => _t('Auf dem Gerät', 'On the device');
  String get firmwareInApp => _t('In der App', 'In the app');
  String get firmwareNone => _t('keine (Entwicklungs-Build)', 'none (development build)');
  String get firmwareUpdate => _t('Aktualisieren', 'Update');
  String get firmwareReinstall => _t('Neu aufspielen', 'Install again');
  String get firmwareConfirmTitle => _t('Firmware aufspielen?', 'Install firmware?');
  String firmwareConfirm(String version) => _t(
        'Das Gerät startet in seinen Bootloader, bekommt Firmware $version und startet neu. Das dauert etwa '
            '30 Sekunden. Bitte das Kabel währenddessen nicht ziehen. Einstellungen und Ausrichtung bleiben '
            'erhalten.',
        'The device restarts into its bootloader, gets firmware $version and restarts. This takes about 30 '
            'seconds. Please do not unplug it meanwhile. Settings and orientation are kept.',
      );
  String get firmwareStart => _t('Aufspielen', 'Install');
  String firmwareStage(FlashStage stage) => switch (stage) {
        FlashStage.connecting => _t('Bootloader wird gestartet …', 'Starting the bootloader …'),
        FlashStage.erasing => _t('Speicher wird gelöscht …', 'Erasing …'),
        FlashStage.writing => _t('Firmware wird geschrieben …', 'Writing firmware …'),
        FlashStage.verifying => _t('Wird geprüft …', 'Verifying …'),
        FlashStage.restarting => _t('Gerät startet neu …', 'Restarting the device …'),
        FlashStage.done => _t('Fertig', 'Done'),
      };
  String get firmwareDone => _t('Firmware aufgespielt. Das Gerät verbindet sich gleich wieder.',
      'Firmware installed. The device reconnects in a moment.');
  String firmwareFailed(String reason) => _t(
        'Aufspielen fehlgeschlagen: $reason. Das Gerät lässt sich jederzeit erneut flashen, auch wenn es '
            'gerade nichts anzeigt.',
        'Installing failed: $reason. The device can always be flashed again, even if it shows nothing now.',
      );
  String get firmwareRetry => _t('Erneut versuchen', 'Try again');
  String get firmwareUnsupported => _t('Auf diesem System noch nicht möglich.', 'Not possible on this system yet.');
  String get deviceDisplay => _t('Anzeige', 'Display');
  String get deviceBehaviour => _t('Verhalten', 'Behaviour');
  String get deviceTransfer => _t('Übertragung', 'Transfer');
  String get followLightroomHint => _t(
        'Bewegst du in Lightroom einen Regler mit der Maus, wechselt das Gerät dorthin, und du kannst am '
            'Drehknopf weitermachen.',
        'When you move a slider in Lightroom with the mouse, the device goes there and you can continue with '
            'the knob.',
      );
  String get sendHint => _t(
        'Änderungen werden automatisch übertragen. Hiermit lässt sich die Konfiguration erneut senden, falls '
            'das Gerät etwas anderes zeigt als die App.',
        'Changes are sent automatically. This sends the configuration again if the device shows something '
            'other than the app.',
      );
  String get orientation => _t('Ausrichtung des Displays', 'Orientation of the display');
  String orientationValue(int degrees) => degrees == 0 ? _t('aufrecht', 'upright') : '$degrees°';
  String get rotateDisplay => _t('Drehen …', 'Rotate …');
  String get rotateUpright => _t('Aufrecht', 'Upright');
  String get rotateHint => _t(
        'Jetzt am Drehknopf des Geräts drehen, bis das Bild gerade steht. Speichern hier oder durch '
            'Druck auf den Knopf.',
        'Now turn the knob of the device until the picture is level. Save here or by pressing the knob.',
      );
  String get rotateNeedsFirmware => _t(
        'Braucht ein verbundenes Gerät mit Firmware 0.6 oder neuer.',
        'Needs a connected device with firmware 0.6 or newer.',
      );
  String get librarySection => _t('In der Bibliothek', 'In the Library');
  String get libraryIntro => _t(
        'Solange Lightroom die Bibliothek zeigt, blättert der Drehknopf durch die Fotos, und das Display '
            'zeigt Dateiname, Sterne, Farbe und Markierung.',
        'While Lightroom shows the Library, the knob goes through the photos and the display shows file '
            'name, stars, colour label and flag.',
      );
  String get libraryEnabled => _t('Bibliotheks-Modus verwenden', 'Use the Library mode');
  String get libraryAction => _t('Aktion', 'Action');
  String get libraryAdvance => _t('Danach zum nächsten Foto', 'Then go to the next photo');
  String get libraryUndoHint => _t(
        'Dieselbe Aktion noch einmal nimmt die Markierung zurück; dabei bleibt das Foto stehen.',
        'The same action again takes the mark back and stays on the photo.',
      );
  String get libraryKnob => _t('Drehknopf', 'Knob');
  String get libraryKnobHint => _t(
        'Drehen: nächstes oder vorheriges Foto. Drücken: zwischen Bibliothek und Entwickeln wechseln. '
            'In Entwickeln wird ein Regler durch Tippen auf das Display gewählt.',
        'Turn: next or previous photo. Press: switch between Library and Develop. '
            'In Develop a slider is selected by tapping the display.',
      );
  String get libraryTap => _t('Tippen', 'Tap');
  String get libraryDoubleTap => _t('Doppeltippen', 'Double tap');
  String libraryMark(LibraryMark mark) => switch (mark) {
        LibraryMark.none => _t('Aus', 'Off'),
        LibraryMark.pick => _t('Als markiert kennzeichnen', 'Flag as pick'),
        LibraryMark.reject => _t('Als abgelehnt kennzeichnen', 'Flag as rejected'),
        LibraryMark.star1 => _t('1 Stern', '1 star'),
        LibraryMark.star2 => _t('2 Sterne', '2 stars'),
        LibraryMark.star3 => _t('3 Sterne', '3 stars'),
        LibraryMark.star4 => _t('4 Sterne', '4 stars'),
        LibraryMark.star5 => _t('5 Sterne', '5 stars'),
        LibraryMark.red => _t('Farbe Rot', 'Red label'),
        LibraryMark.yellow => _t('Farbe Gelb', 'Yellow label'),
        LibraryMark.green => _t('Farbe Grün', 'Green label'),
        LibraryMark.blue => _t('Farbe Blau', 'Blue label'),
        LibraryMark.purple => _t('Farbe Lila', 'Purple label'),
      };
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
  String get sectionSliders => _t('Regler', 'Sliders');
  String get sectionLibrary => _t('Bibliothek', 'Library');
  String get sectionDevice => _t('Gerät', 'Device');
  String get sectionTime => _t('Zeiterfassung', 'Time tracking');
  String get sectionInfo => _t('Infos', 'About');
  String get tagline => _t('Drehregler für Lightroom Classic mit Zeiterfassung', 'Rotary controller for Lightroom Classic with time tracking');
  String get versions => _t('Versionen und Verbindung', 'Versions and connection');
  String get license => _t('Lizenz', 'Licence');
  String get licenseText => _t(
        'Darkdial ist freie Software, veröffentlicht unter der GNU General Public License Version 3 (GPLv3). '
            'Du darfst sie nutzen, weitergeben und verändern, solange Weitergaben unter derselben Lizenz stehen '
            'und der Quelltext mitgeliefert wird.',
        'Darkdial is free software, published under the GNU General Public License version 3 (GPLv3). '
            'You may use, share and modify it, as long as what you pass on is under the same licence '
            'and comes with its source code.',
      );
  String get licenseCondition => _t(
        'Zusätzliche Bedingung (GPLv3 Abschnitt 7 b): Der Hinweis auf meine-belichtungszeit.de muss in jeder '
            'weitergegebenen oder veränderten Fassung erhalten bleiben – auf dem Gerät im Startlogo '
            '(„by meine-belichtungszeit.de“), in dieser App und im Lightroom-Plugin '
            '(„powered by meine-belichtungszeit.de“).',
        'Additional term (GPLv3 section 7 b): the credit to meine-belichtungszeit.de must be kept in every '
            'version that is passed on or modified – on the device in the start-up logo '
            '("by meine-belichtungszeit.de"), in this app and in the Lightroom plug-in '
            '("powered by meine-belichtungszeit.de").',
      );
  String get licenseMarks => _t(
        'Der Name „Darkdial“, das Darkdial-Logo und das Logo von meine-Belichtungszeit stehen nicht unter der GPL. '
            'Darkdial ist nicht mit Adobe verbunden; Lightroom ist eine Marke von Adobe Inc.',
        'The name "Darkdial", the Darkdial logo and the meine-Belichtungszeit logo are not covered by the GPL. '
            'Darkdial is not affiliated with Adobe; Lightroom is a trademark of Adobe Inc.',
      );
  String get timeTracking => _t('Zeiterfassung …', 'Time tracking …');
  String get poweredBy => 'powered by meine-belichtungszeit.de';
  String get unnamed => _t('Unbenannt', 'Unnamed');
  String get newJob => _t('Neuer Job', 'New job');
  String get start => _t('Starten', 'Start');
  String get stop => _t('Stopp', 'Stop');
  String get noClock => _t('Keine Uhr läuft', 'No clock running');
  /// [count] unnamed jobs and clients together.
  String unnamedHint(int count) => _t(
        count == 1 ? '1 unbenannter Eintrag – bitte benennen' : '$count unbenannte Einträge – bitte benennen',
        count == 1 ? '1 unnamed item – please name it' : '$count unnamed items – please name them',
      );
  String get noClient => _t('Ohne Kunde', 'No client');
  String get renameClient => _t('Kunde umbenennen', 'Rename client');
  String get newClient => _t('Neuer Kunde', 'New client');
  String get newClientHint => _t(
        'Am Gerät lassen sich Jobs nur für vorhandene Kunden starten.',
        'On the device, jobs can only be started for existing clients.',
      );
  String get renameClientHint => _t(
        'Gibt es schon einen Kunden mit diesem Namen, werden beide zusammengeführt.',
        'If a client with this name exists already, the two are merged.',
      );
  String get unnamedClientHint => _t('Kunde ist noch unbenannt', 'Client has no name yet');
  String get deleteJob => _t('Löschen …', 'Delete …');
  String deleteJobTitle(String name) => _t('„$name“ löschen?', 'Delete "$name"?');
  String deleteJobWarning(int entries, String total) => _t(
        'Der Job wird mit allen erfassten Zeiten endgültig gelöscht: $entries ${entries == 1 ? 'Eintrag' : 'Einträge'}, '
            'zusammen $total Stunden. Das lässt sich nicht rückgängig machen. Archivieren behält die Zeiten.',
        'The job is deleted for good with all recorded times: $entries ${entries == 1 ? 'entry' : 'entries'}, '
            '$total hours in total. This cannot be undone. Archiving keeps the times.',
      );
  String get deleteForever => _t('Endgültig löschen', 'Delete for good');
  String get factoryReset => _t('Auf Werkseinstellungen zurücksetzen …', 'Reset to factory settings …');
  String get factoryResetTitle => _t('Alles zurücksetzen?', 'Reset everything?');
  String factoryResetWarning(int jobs, int entries) => _t(
        'Gelöscht werden: alle $jobs Jobs mit $entries Zeiteinträgen, alle Kunden und Lightroom-Zuordnungen, '
            'die Reglerauswahl mit Reihenfolge, Kurzwörtern und Schrittweiten. Das Gerät erhält wieder die '
            'Standardregler. Das lässt sich nicht rückgängig machen. Exportiere vorher bei Bedarf die Zeiten als CSV.\n\n'
            'Das Lightroom-Plugin und der Autostart bleiben installiert.',
        'This deletes: all $jobs jobs with $entries time entries, all clients and Lightroom assignments, '
            'the selection of controls with their order, short words and step sizes. The device gets the default '
            'controls again. This cannot be undone. Export the times as CSV first if you need them.\n\n'
            'The Lightroom plug-in and the login item stay installed.',
      );
  String get factoryResetConfirm => _t('Alles löschen', 'Delete everything');
  String get factoryResetDone => _t('Zurückgesetzt.', 'Reset done.');
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
  String get noJobs => _t(
        'Noch keine Kunden und Jobs. Lege zuerst einen Kunden an – am Gerät wählst du dann Kunde und Job.',
        'No clients or jobs yet. Create a client first – on the device you then choose client and job.',
      );
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
