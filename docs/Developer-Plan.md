# Darkdial – Developer-Plan

Oct 1, 2026 · @Andres

## Ziel und Umfang

Wir bauen einen dedizierten Hardware-Controller für Lightroom Classic auf Basis des Elecrow CrowPanel 1.46″ Rotary (ESP32-S3, 360×360, Touch, Drehknopf mit Klick, 8 WS2812-LEDs). Dazu kommen ein eigenes Lua-Plugin und ein Desktop-Service in Flutter, der in der Menüleiste lebt. MIDI2LR wird nicht verwendet, sondern für genau dieses Gerät ersetzt.

**MVP umfasst:**

- Gerät: Symbol-Karussell, Wertebearbeitung per Drehknopf, Ring als Werteskala, Live-Rückmeldung der aktuellen Werte aus Lightroom
- Plugin: Regler im Entwickeln-Modul lesen und setzen, Änderungen per Maus zurückmelden
- Desktop-App: Menüleisten-Icon mit Verbindungsstatus, Konfiguration der verfügbaren Regler, Reihenfolge, Schrittweite
- Verteilung: signierte und notarisierte App, die das Plugin selbst installiert

**Nicht im MVP:** Firmware-Update aus der App, Presets/Profile anwenden, Masken- und Pinselwerkzeuge, BLE- und WLAN-Transport. MIDI läuft ausschließlich über USB.

Zielplattform für den MVP ist macOS 13 oder neuer mit aktuellem Lightroom Classic. **Windows ist fest eingeplant** und folgt nach dem macOS-MVP; Flutter, Lua und `flutter_midi_command` tragen beide Systeme.

Das Projekt wird kostenlos und quelloffen auf GitHub veröffentlicht. Ein Apple-Developer-Konto für Signierung und Notarisierung ist vorhanden.

## Marke und Logo

Das Logo ist die Wortmarke DARKDIAL in einem schwarzen Kreis mit Streiflicht am Rand. Der Kreis greift die Form des Geräts auf; „DARK“ steht kräftig in Weiß, „DIAL“ leichter in Grau. Maßgeblich ist die Fassung auf schwarzem Grund.

&#91;image: Darkdial-Logo auf schwarzem Grund\]

**Einsatz:**

- Boot-Screen auf dem runden 360×360-Display, ohne Anpassung der Form
- App-Icon auf macOS und Windows
- GitHub-Repo, README und Release-Seiten

**Vor dem Einsatz zu erledigen:**

- [ ] Signet für kleine Größen entwerfen, etwa der Ring mit Lichtkante oder das Λ; das Menüleisten-Icon braucht eine einfarbige Fassung bei 16 bis 22 pt
- [ ] Vektorversion der Wortmarke anlegen, Buchstaben in Pfade umgewandelt, plus flache Variante ohne Verlauf
- [ ] Variante für helle Hintergründe, etwa für die README im Light-Mode
- [ ] Lesbarkeit von „DIAL“ in Grau auf Schwarz auf dem Gerät und als Favicon prüfen
- [ ] Schriftlizenz klären, falls die Wortmarke auf einer gekauften Schrift basiert

**Rechte:** Name und Logo stehen nicht unter der GPLv3. Ein Satz in der README stellt klar, dass Forks den Code nutzen dürfen, aber nicht unter dem Namen Darkdial und nicht mit diesem Logo auftreten.

## Systemarchitektur

Das System besteht aus vier Teilen in einer Kette. Die Logik sitzt im Desktop-Service, damit Firmware und Lua-Plugin klein und stabil bleiben.

&#91;embedded content: Systemarchitektur · 4 Teile, 3 Verbindungen\]

Jede Verbindung arbeitet in beide Richtungen: Eingaben laufen nach unten, Werte und Status laufen zurück aufs Display.

## Kommunikationsprotokoll

Entscheidung: Gerät und Service sprechen USB-MIDI, Service und Plugin sprechen ein eigenes Textprotokoll über LrSocket. MIDI ist am Mac treiberlos, funktioniert später identisch über BLE-MIDI und Netzwerk-MIDI und trägt mit SysEx auch die Konfiguration.

### Gerät ↔ Service (MIDI)

| Richtung | Nachricht | MIDI-Form | Zweck |
| --- | --- | --- | --- |
| Gerät → Service | Drehung | CC, relativ (Delta mit Vorzeichen) | Wert des aktiven Reglers ändern |
| Gerät → Service | Regler gewählt / verlassen | SysEx | Plugin weiß, welcher Regler aktiv ist, schickt Startwert |
| Gerät → Service | Hello | SysEx | Firmware-Version, Protokollversion, Geräte-ID |
| Service → Gerät | Konfiguration | SysEx | Liste der Slots: Parameter-ID, Icon-ID, Label, Bereich, Schrittweite |
| Service → Gerät | Wert | SysEx (oder NRPN) | aktueller Wert, normiert, für Ring und Zahl |
| Service → Gerät | Status | SysEx | Lightroom verbunden, Entwickeln-Modul aktiv, Foto gewählt |

Die Geräte-Herstellerkennung im SysEx nutzt die nicht-kommerzielle ID 0x7D. Jede SysEx-Nachricht trägt einen Typ-Byte und eine Protokollversion. Werte werden als 14-Bit-Zahl normiert übertragen; die Umrechnung auf echte Einheiten (EV, Kelvin) macht der Service.

### USB-Gerät: MIDI plus serielle Schnittstelle

Das Board meldet sich als zusammengesetztes USB-Gerät mit MIDI und serieller Schnittstelle (CDC), beides über TinyUSB im OTG-Modus und auf macOS wie Windows ohne Treiber. Die serielle Schnittstelle dient zum Flashen und für Debug-Ausgaben.

- Hängt die Firmware, verschwindet auch der serielle Port. Dann hilft einmal BOOT + RESET.
- Frühe Bootmeldungen und Absturzberichte laufen nur über den UART-Anschluss. Ein USB-TTL-Adapter gehört deshalb zur Entwicklungsausstattung.
- Hardware-JTAG über USB entfällt.
- Über den seriellen Port können GitHub-Nutzer die Firmware später direkt aus dem Browser flashen, etwa mit ESP Web Tools.
- Die USB-Kennung (VID/PID) bleibt bewusst die Standardkennung von Espressif/TinyUSB; es wird keine eigene PID beantragt.

### Geräteerkennung

Die App erkennt das Gerät nicht über VID/PID, sondern in drei Stufen. Erst wenn alle drei bestanden sind, gilt ein MIDI-Port als „unser“ Drehregler.

1. **Gerätename als Vorfilter:** Die Firmware meldet einen festen, eindeutigen USB-Produktnamen, kürzer als 31 Zeichen, weil Windows längere Namen abschneidet.
2. **MIDI-Identity-Request:** Die App sendet die standardisierte Universal-SysEx-Geräteabfrage. Das Gerät antwortet mit Hersteller-ID 0x7D, Gerätekennung und Firmware-Version.
3. **Hello-Handshake:** Das Gerät schickt eine feste Projektsignatur, die Protokollversion und eine Seriennummer aus seiner MAC-Adresse.

So bleibt die Erkennung zuverlässig, auch wenn andere ESP32-Geräte dieselbe Standardkennung tragen. Mehrere Drehregler lassen sich über die Seriennummer unterscheiden, Versionskonflikte fallen direkt beim Verbinden auf.

### Service ↔ Plugin (LrSocket)

LrSocket arbeitet nur auf localhost und je Socket nur in eine Richtung. Wir nutzen daher zwei feste Ports, einen zum Senden und einen zum Empfangen. Nachrichten sind zeilenbasiertes JSON, zum Beispiel `set`, `delta`, `get`, `value`, `status`, `hello`.

Der Service puffert Drehdeltas und gibt sie gebündelt ans Plugin weiter (Richtwert 30 bis 50 Hz). Das hält Lightroom flüssig, auch wenn der Knopf schnell gedreht wird.

**Zu dokumentieren in Phase 1:** vollständige Nachrichtenliste, Byte-Layout der SysEx-Nachrichten, Versionsregeln, Verhalten bei unbekannten Nachrichten.

## Gerät: Firmware und UI

Die Firmware entsteht in der Arduino IDE auf dem ESP32-Arduino-Core 3.x mit LVGL 9 und dem eingebauten USB-MIDI des Cores. Vom Elecrow-Werkscode (Core 2.0.14, LVGL 8.3) übernehmen wir nur die Initialisierung von Display, Touch, Encoder, LEDs und Hintergrundbeleuchtung und portieren sie.

**Portierungspunkte:** Das Display braucht LovyanGFX mit dem Treiber `Panel_ST77961`. Die LVGL-Anbindung (Flush-Callback, Display, Eingabegeräte) wird für LVGL 9 neu geschrieben. Die Hintergrundbeleuchtung wechselt auf die geänderte LEDC-API von Core 3.x. Ob LovyanGFX mit diesem Treiber unter 3.x sauber läuft, klärt Phase 0; Rückfall ist Core 2.0.14 mit Adafruit TinyUSB.

### Bedienlogik

Geblättert wird ausschließlich mit dem Drehknopf. Touch kennt nur Tippen, das dem Klick gleichgestellt ist. Einen langen Druck gibt es nicht.

1. **Auswahlmodus:** Drehen blättert durch die konfigurierten Regler. In der Mitte steht das Symbol, darunter das Kurzwort, darunter der aktuelle Wert. Der Ring zeigt den Wert gedimmt.
2. **Klick oder Tippen** wählt den Regler. Der Ring wird aktiv dargestellt.
3. **Bearbeitungsmodus:** Drehen verändert den Wert, Ring und Zahl folgen live.
4. **Erneuter Klick oder Tippen** führt zurück in den Auswahlmodus, auf dem zuletzt gewählten Regler.

Der Zahlenwert ist in beiden Modi immer sichtbar.

### Gestaltung des Rings

- **Bipolare Regler** (Belichtung, Kontrast, Lichter, Tiefen, Temperatur, Tonung): Null liegt oben, der Ring füllt sich von dort nach links oder rechts.
- **Unipolare Regler** (Schärfen, Rauschreduzierung, Körnung): der Ring füllt sich von unten links im Uhrzeigersinn.
- Der Ring nutzt rund 300°, die Lücke unten bleibt für Statusanzeigen.
- Beim Wechsel zwischen Reglern gleitet das Symbol seitlich, der Ring blendet um.

### Symbole und Texte

Das Icon-Set wird selbst gestaltet: angelehnt an die Bildsprache von Lightroom, aber ohne dessen Grafiken zu kopieren oder nachzuzeichnen, damit keine Lizenz- oder Markenrechte berührt werden. Gleiche Strichstärke, gleiches Raster, auf schwarzem Grund getestet. Die Symbole liegen als LVGL-Bilder im Flash; die Desktop-App schickt nur Icon-IDs.

Kurzwörter gibt es auf Deutsch und Englisch, umschaltbar in der Desktop-App. Sie sind auf etwa 10 Zeichen begrenzt.

### Zusätzliche Zustände

| Zustand | Anzeige |
| --- | --- |
| Kein Service verbunden | Symbol „nicht verbunden“, Ring grau |
| Lightroom nicht im Entwickeln-Modul | Beim ersten Dreh wechselt Lightroom automatisch ins Entwickeln-Modul |
| Kein Foto gewählt | Hinweis, Drehen ohne Wirkung |
| Konfiguration empfangen | kurze Bestätigung |

### LED-Ring und Drehgefühl

Die 8 WS2812-LEDs zeigen den Modus an, etwa weiß im Auswahlmodus und eine Akzentfarbe im Bearbeitungsmodus. Die Firmware wertet die Drehgeschwindigkeit aus: langsames Drehen gibt kleine Schritte, schnelles Drehen große. Die Konfiguration wird im NVS gespeichert, damit das Gerät nach dem Einstecken sofort seine Regler zeigt.

## Icon-Liste für das Display

Das Display braucht 24 Regler-Icons und 4 Status-Icons, zusammen 28 Entwürfe. Die 24 HSL-Regler teilen sich drei Icons; die Farbe kommt als farbiger Punkt oder Ringfarbe dazu.

### Regler

| Nr. | Gruppe | Einstellung in Lightroom | Kurzwort DE | Kurzwort EN | Ring | Icon-Status |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Weißabgleich | Temperatur | Temperatur | Temp | bipolar | Offen |
| 2 | Weißabgleich | Tonung | Tonung | Tint | bipolar | Offen |
| 3 | Ton | Belichtung | Belichtung | Exposure | bipolar | Offen |
| 4 | Ton | Kontrast | Kontrast | Contrast | bipolar | Offen |
| 5 | Ton | Lichter | Lichter | Highlights | bipolar | Offen |
| 6 | Ton | Tiefen | Tiefen | Shadows | bipolar | Offen |
| 7 | Ton | Weiß | Weiß | Whites | bipolar | Offen |
| 8 | Ton | Schwarz | Schwarz | Blacks | bipolar | Offen |
| 9 | Präsenz | Struktur | Struktur | Texture | bipolar | Offen |
| 10 | Präsenz | Klarheit | Klarheit | Clarity | bipolar | Offen |
| 11 | Präsenz | Dunst entfernen | Dunst | Dehaze | bipolar | Offen |
| 12 | Präsenz | Dynamik | Dynamik | Vibrance | bipolar | Offen |
| 13 | Präsenz | Sättigung | Sättigung | Saturation | bipolar | Offen |
| 14 | Details | Schärfen, Betrag | Schärfen | Sharpen | unipolar | Offen |
| 15 | Details | Rauschreduzierung, Luminanz | Rauschen | Noise | unipolar | Offen |
| 16 | Effekte | Vignettierung nach Freistellen, Betrag | Vignette | Vignette | bipolar | Offen |
| 17 | Effekte | Körnung, Stärke | Körnung | Grain | unipolar | Offen |
| 18 | Gradationskurve | Lichter | Lichter | Highlights | bipolar | Offen |
| 19 | Gradationskurve | Helle Mitteltöne | Hell | Lights | bipolar | Offen |
| 20 | Gradationskurve | Dunkle Mitteltöne | Dunkel | Darks | bipolar | Offen |
| 21 | Gradationskurve | Tiefen | Tiefen | Shadows | bipolar | Offen |
| 22 | HSL | Farbton, je Farbe | Farbton | Hue | bipolar | Offen |
| 23 | HSL | Sättigung, je Farbe | Sättigung | Saturation | bipolar | Offen |
| 24 | HSL | Luminanz, je Farbe | Luminanz | Luminance | bipolar | Offen |

HSL gilt für acht Farben: Rot, Orange, Gelb, Grün, Aquamarin, Blau, Lila, Magenta (EN: Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta). Das Kurzwort bleibt gleich, die Farbe zeigt der Punkt am Icon.

**Namensgleiche Regler:** Lichter und Tiefen gibt es im Ton und in der Gradationskurve, Sättigung in Präsenz und HSL. Die Icons müssen den Unterschied tragen, weil das Kurzwort identisch ist. Vorschlag: Alle Kurven-Icons teilen ein Kurvenmotiv, alle HSL-Icons ein Farbkreismotiv.

### Status

| Nr. | Zustand | Kurzwort DE | Kurzwort EN | Icon-Status |
| --- | --- | --- | --- | --- |
| S1 | Kein Service verbunden | Getrennt | Offline | Offen |
| S2 | Kein Foto gewählt | Kein Foto | No photo | Offen |
| S3 | Konfiguration empfangen | Geladen | Loaded | Offen |
| S4 | Wechsel ins Entwickeln-Modul | Entwickeln | Develop | Offen |

**Gestaltungsrahmen:** Icons sitzen in der Displaymitte im Kreis, der Ring läuft außen um sie herum. Alle Kurzwörter haben höchstens 10 Zeichen. Gleiche Strichstärke und gleiches Raster für alle 28 Icons, geprüft auf Schwarz und auf dem echten Display.

## Lightroom-Plugin (Lua)

Das Plugin ist ein schlanker Übersetzer zwischen Socket-Nachrichten und dem Lightroom SDK. Logik wie Schrittweiten, Beschleunigung und Konfiguration liegt im Service, nicht im Plugin, weil Lua im SDK schwer zu testen und zu debuggen ist.

**Aufgaben:**

- Beim Start von Lightroom automatisch laden, beide Sockets öffnen und bei Verbindungsverlust in einer Schleife neu verbinden
- Werte über `LrDevelopController` lesen, setzen und den Wertebereich je Parameter abfragen
- Änderungen beobachten, die per Maus oder Tastatur in Lightroom passieren, und sie an den Service melden, damit das Display stimmt
- Wechsel des Fotos und des Moduls erkennen und den Status melden
- Beim ersten Dreh außerhalb des Entwickeln-Moduls automatisch dorthin wechseln

**Wichtige Einschränkungen:**

- `LrDevelopController` arbeitet nur im Entwickeln-Modul. Kommt eine Eingabe in einem anderen Modul an, wechselt das Plugin zuerst ins Entwickeln-Modul und wendet die Eingabe danach an.
- Schnelle `setValue`-Folgen können Lightroom träge machen. Ob `startTracking` dafür flüssiger ist, klärt der Spike in Phase 0.
- Die Temperatur verhält sich nicht linear und hat bei Raw und JPEG unterschiedliche Bereiche. Das Plugin meldet deshalb den Bereich je Foto mit.

Das Plugin liegt als `.lrplugin`-Bundle im Modules-Ordner von Lightroom und wird dort ohne Plug-in-Manager automatisch geladen. Es trägt eine Versionsnummer, die der Service beim Hello prüft.

## Desktop-App (Flutter)

Die App läuft als reiner Menüleisten-Service ohne Dock-Icon und öffnet nur bei Bedarf ein Konfigurationsfenster. Sie ist die zentrale Logikschicht zwischen Gerät und Plugin.

### Menüleiste

- Icon mit drei Zuständen: alles verbunden, nur Gerät oder nur Lightroom verbunden, nichts verbunden
- Menü: Status beider Verbindungen, aktiver Regler, „Konfigurieren …“, „Beim Anmelden starten“, Beenden
- Autostart über die macOS-Anmeldeobjekte (SMAppService)

### Konfigurationsfenster

- Liste aller unterstützten Entwickeln-Parameter, gruppiert wie in Lightroom
- Per Schalter aktivieren, per Drag & Drop in Reihenfolge bringen
- Je Regler: Kurzwort anpassen, Symbol wählen, Schrittweite und Empfindlichkeit einstellen
- Sprache der Kurzwörter: Deutsch oder Englisch
- Live-Vorschau des runden Displays im Fenster
- „Aufs Gerät übertragen“ schickt die Konfiguration per SysEx; zusätzlich automatisch beim Verbinden
- Info-Bereich: Firmware-, Plugin- und App-Version, Hinweis bei Versionskonflikt

### Unterstützte Regler

Alles, was beim Entwickeln sinnvoll mit einem Drehregler bedient wird. Die Standardauswahl umfasst 13 Regler, damit das Durchblättern schnell bleibt.

| Gruppe | Standardmäßig aktiv | Zuschaltbar |
| --- | --- | --- |
| Weißabgleich | Temperatur, Tonung |  |
| Ton | Belichtung, Kontrast, Lichter, Tiefen, Weiß, Schwarz |  |
| Präsenz | Struktur, Klarheit, Dunst entfernen, Dynamik, Sättigung |  |
| Details |  | Schärfen, Rauschreduzierung |
| Effekte |  | Vignette, Körnung |
| Gradationskurve |  | Lichter, helle und dunkle Mitteltöne, Tiefen |
| HSL |  | Farbton, Sättigung, Luminanz je Farbe (24 Regler) |

### Technische Bausteine

| Aufgabe | Ansatz |
| --- | --- |
| Menüleisten-Icon, Fenster | Flutter-Pakete für Tray und Fensterverwaltung, `LSUIElement` gegen das Dock-Icon |
| MIDI | `flutter_midi_command` auf macOS und Windows |
| Socket zum Plugin | Dart-Sockets auf localhost |
| Konfiguration speichern | JSON-Datei im App-Datenordner |
| Autostart | SMAppService auf macOS, Autostart-Eintrag auf Windows |

Phase 0 prüft `flutter_midi_command` auf beiden Systemen, vor allem SysEx und An- und Abstecken des Geräts. Nur wenn es dort hakt, wird die MIDI-Anbindung nativ je Plattform gebaut.

## Installer und Verteilung

Flutter selbst baut keinen Installer, nur die `.app`. Ein separater Installer ist aber unnötig: Die App installiert das Plugin selbst. Das ist der empfohlene Weg.

**Ablauf für Nutzer:**

1. DMG laden, App in den Programme-Ordner ziehen
2. App starten; ein Einrichtungsfenster kopiert das mitgelieferte `.lrplugin` in den Modules-Ordner von Lightroom und richtet den Autostart ein
3. Lightroom neu starten, fertig

Bei jedem Start prüft die App die installierte Plugin-Version und aktualisiert sie bei Bedarf. Eine Deinstallations-Funktion im Menü entfernt Plugin und Autostart wieder.

**Voraussetzungen:**

- Verteilung außerhalb des App Store: Die App-Sandbox würde das Schreiben in Adobes Ordner verbieten.
- Signierung mit Developer-ID-Zertifikat und Notarisierung bei Apple, sonst blockiert Gatekeeper den Start. Das Developer-Konto ist vorhanden.
- Updates der App später über Sparkle oder eine einfache Versionsprüfung gegen einen eigenen Server.

**Alternative:** ein klassisches `.pkg` mit `pkgbuild`/`productbuild` und Postinstall-Skript. Das lohnt sich nur bei Verteilung über MDM in Firmen, weil der Modules-Ordner im Benutzerverzeichnis liegt und das im Paket umständlich ist.

**Windows:** gleiches Prinzip. Ein Windows-Installer legt die App ab, die App kopiert das Plugin beim Start in den Lightroom-Modules-Ordner unter Windows und richtet den Autostart ein. Das Tray-Icon sitzt dort im Infobereich der Taskleiste.

**GitHub-Release:** Je Version gibt es das signierte DMG, den Windows-Installer und die Firmware-Datei. Die Firmware lässt sich zusätzlich per Browser-Flasher aufspielen.

## Phasenplan

Der Plan beginnt mit drei kurzen Spikes, weil die größten Unbekannten technischer Natur sind: Laufen USB-MIDI und das Display auf demselben Arduino-Core, und bleibt Lightroom bei schnellen Wertänderungen flüssig? Erst danach lohnt sich die UI-Arbeit.

&#91;embedded content: Phasenplan · 6 Phasen, je ein Gate\]

Firmware und Plugin werden in Phase 2 jeweils gegen ein einfaches Testwerkzeug statt gegen die fertige App gebaut. Da eine Person alles baut, laufen 2a und 2b nacheinander; die getrennten Tests helfen trotzdem, Fehler eindeutig einer Schicht zuzuordnen. Die Dauer lässt sich nach Phase 0 deutlich besser schätzen.

## Risiken und Entscheidungen

### Risiken

| Risiko | Auswirkung | Gegenmaßnahme |
| --- | --- | --- |
| Elecrow-Werkscode ist für Core 2.0.14, LovyanGFX mit `Panel_ST77961` und LVGL 8.3 geschrieben; Core 3.x ändert APIs grundlegend | Display-Initialisierung muss portiert werden | Spike in Phase 0; Rückfall Core 2.0.14 mit Adafruit TinyUSB |
| Adafruit TinyUSB und Core 3.x kollidieren beim Kompilieren | kein Mischweg möglich | unter 3.x nur das eingebaute USB-MIDI des Cores nutzen |
| Firmware-Hänger lassen den seriellen USB-Port verschwinden | Flashen nur per BOOT + RESET | Vorgehen dokumentieren, UART-Adapter bereithalten |
| `flutter_midi_command` hakt bei SysEx oder Hot-Plug | MIDI-Schicht muss nativ gebaut werden | Test auf macOS und Windows in Phase 0 |
| Schnelle Wertänderungen machen Lightroom träge | ruckelige Bedienung | Deltas im Service bündeln, `startTracking` testen |
| LrSocket-Verbindungen brechen bei Lightroom-Neustart ab | Gerät zeigt falschen Status | Reconnect-Schleife auf beiden Seiten, Heartbeat |
| Automatischer Modulwechsel stört beim Sortieren in der Bibliothek | ungewollte Sprünge | im Alltagstest beobachten, notfalls abschaltbar machen |

Quellen zur Core-Frage: [Control Surface: MIDI over USB](https://tttapa.github.io/Control-Surface/Doxygen/d8/d4a/md_pages_MIDI-over-USB.html), [PlatformIO-Forum: TinyUSB und Core 3.x](https://community.platformio.org/t/tinyusb-dosent-complie-for-esp32-s3-usbmidi/45412), [Makerguides: CrowPanel 1.46](https://www.makerguides.com/getting-started-with-crowpanel-1-46inch-hmi-esp32-rotary-display/).

### Getroffene Entscheidungen

| Thema | Entscheidung |
| --- | --- |
| Arduino-Core | 3.x mit eingebautem USB-MIDI |
| Grafik | LVGL 9 |
| USB | MIDI plus serielle Schnittstelle (CDC) |
| MIDI-Transport | nur USB |
| Touch | nur Tippen, Blättern per Drehknopf |
| Langer Druck | keiner |
| Zahlenwert | immer sichtbar |
| Icons | eigene Gestaltung, an Lightroom angelehnt, ohne Lizenzrisiko |
| Sprache | Deutsch und Englisch, in der App umschaltbar |
| Regler | alle fürs Entwickeln sinnvollen, 13 standardmäßig aktiv |
| Außerhalb von Entwickeln | automatischer Wechsel ins Entwickeln-Modul |
| MIDI in Flutter | `flutter_midi_command` |
| Plattformen | macOS zuerst, Windows eingeplant |
| Veröffentlichung | kostenlos und quelloffen auf GitHub |
| Team | eine Person für Firmware, Plugin und App |
| USB-Kennung | Standardkennung, keine Beantragung; Erkennung über Name, Identity-Request und Hello |
| Lizenz | GPLv3 für Firmware, Plugin und App; keine Dateien aus dem Adobe SDK im Repo, Herkunft von Elecrow-Code prüfen |
| Name | Darkdial, auch als USB-Gerätename |
| Logo | Wortmarke im schwarzen Kreis mit Streiflicht; Name und Logo nicht unter GPLv3 |

### Noch offen

- [ ] Lizenz für Icons und Design-Assets, zum Beispiel CC BY-SA 4.0
- [ ] Verfügbarkeit von „Darkdial“ prüfen: GitHub, Domain, Markenregister
