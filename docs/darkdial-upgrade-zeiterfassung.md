# Darkdial – Upgrade: Zeiterfassung

**Status:** Konzept, umzusetzen nach Abschluss der Basis (Phasen 0–5 des Developer-Plans)
**Betrifft:** Firmware, Desktop-App (Flutter), Lightroom-Plugin (Lua), Protokoll

---

## 1. Idee

Darkdial bekommt einen zweiten Modus: eine Arbeitszeiterfassung pro Job. Der Drehknopf dient als Start/Stopp-Uhr und zeigt die laufende Zeit an. Die Desktop-App führt Buch, ordnet die Zeiten Jobs zu und bietet Übersicht, Archiv und Suche.

Der Mehrwert gegenüber einer normalen Zeiterfassungs-App: Das Lightroom-Plugin weiß, welche Sammlung oder welcher Ordner gerade bearbeitet wird. Die App kann den passenden Job deshalb vorschlagen, statt dass er gesucht oder eingetippt werden muss.

**Leitprinzip:** Der Reglerworkflow in Lightroom bleibt unberührt. Die Zeiterfassung ist ein eigener Modus, der nur per langem Druck erreichbar ist, und taucht nicht im Regler-Karussell auf.

---

## 2. Geänderte Entscheidung gegenüber der Basis

| Thema | Basis | Mit Upgrade |
| --- | --- | --- |
| Langer Druck | keiner | langer Druck am Drehknopf öffnet die Zeiterfassung |

Alle übrigen Entscheidungen des Developer-Plans gelten unverändert.

---

## 3. Bedienkonzept am Gerät

### 3.1 Langer Druck

- Nur am Drehknopf, nicht per Touch. Touch bleibt bei „nur Tippen“.
- Schwelle etwa 0,7 Sekunden, im Alltagstest feinjustieren.
- Während des Haltens füllt sich der Ring als Rückmeldung.
- Ein normaler Klick wird erst beim Loslassen ausgewertet und nur, wenn die Schwelle nicht erreicht wurde. Klick und langer Druck können sich so nie überschneiden.
- Der lange Druck funktioniert aus jedem Zustand heraus, im Auswahl- wie im Bearbeitungsmodus.

### 3.2 Job-Menü

Öffnet sich nach dem langen Druck. Drehen blättert, Klick oder Tippen wählt, ein erneuter langer Druck schließt das Menü ohne Änderung.

**Reihenfolge der Einträge:**

1. „Stopp“ – nur wenn gerade eine Uhr läuft
2. „Neuer Job“
3. Vorschlag aus Lightroom – der Job, der zur aktuell bearbeiteten Sammlung oder zum Ordner passt, falls vorhanden
4. Weitere aktive Jobs, zuletzt genutzte zuerst

Archivierte Jobs erscheinen nicht. Die Liste ist auf etwa 15 Einträge begrenzt.

**Anzeige je Eintrag:** Kürzel des Jobs (max. 10 Zeichen) als Kurzwort, darüber ein Symbol (Stoppuhr, Plus für „Neuer Job“, Stopp-Symbol für „Stopp“). Beim laufenden Job zusätzlich die bisherige Zeit.

### 3.3 Aktionen

| Auswahl | Wirkung |
| --- | --- |
| Neuer Job | Legt einen unbenannten Job an und startet die Uhr. Anzeigename auf dem Gerät: Datum und Uhrzeit, etwa „01.10. 14:32“. |
| Bestehender Job | Startet die Uhr für diesen Job. Läuft bereits eine andere Uhr, wird sie zuerst gestoppt. |
| Stopp | Stoppt die laufende Uhr. |

Es läuft immer höchstens eine Uhr.

Nach jeder Aktion kehrt das Gerät in den Zustand zurück, aus dem der lange Druck kam, und zeigt kurz eine Bestätigung (z. B. „Gestartet“, „Gestoppt“).

### 3.4 Anzeige bei laufender Uhr

- Im normalen Reglerbetrieb steht die laufende Zeit klein in der Lücke unten im Ring (Format `h:mm`, unter einer Stunde `mm:ss`).
- Im Job-Menü steht die Zeit groß beim laufenden Job.
- Optional: Der LED-Ring zeigt eine laufende Uhr dezent an, etwa durch ein langsames Pulsieren einer LED. Muss sich gegen die Modusanzeige der Basis abgrenzen.

### 3.5 Ohne Verbindung zur App

Die App ist die Quelle der Wahrheit, das Gerät hat keine eigene Echtzeituhr. Ist keine App verbunden, zeigt das Job-Menü nur „Getrennt“ und lässt keine Aktion zu. Eine bereits laufende Uhr läuft in der App weiter; nach dem Wiederverbinden übernimmt das Gerät ihren Zustand.

### 3.6 Neue Icons

| Icon | Verwendung |
| --- | --- |
| Stoppuhr | Jobs im Menü, Zeitanzeige |
| Plus | „Neuer Job“ |
| Stopp | „Stopp“ |

Gestaltung nach den Vorgaben des Basis-Icon-Sets: gleiche Strichstärke, gleiches Raster, transparenter Hintergrund ohne Scheibe, 150 px.

---

## 4. Protokoll-Erweiterung (MIDI/SysEx)

Neue SysEx-Nachrichtentypen, Byte-Layout analog zu den bestehenden Nachrichten. Die Typ-Nummern sollten bereits in Phase 1 der Basis reserviert werden.

| Richtung | Nachricht | Inhalt | Wann |
| --- | --- | --- | --- |
| Gerät → App | Job-Liste anfordern | – | beim Öffnen des Job-Menüs |
| App → Gerät | Job-Liste | je Job: ID, Kürzel, Flag „Vorschlag“, Flag „läuft“ | als Antwort und bei Änderungen |
| Gerät → App | Start | Job-ID oder „neu“ | nach Auswahl |
| Gerät → App | Stopp | – | nach Auswahl |
| App → Gerät | Uhrzustand | läuft ja/nein, Job-ID, Kürzel, bisher verstrichene Sekunden | nach jeder Änderung, beim Verbinden |
| App → Gerät | Bestätigung / Fehler | Code, kurzer Text | nach Start und Stopp |

**Wichtig:** Die App schickt die bisher verstrichenen Sekunden, keinen Zeitstempel, weil das Gerät keine absolute Uhrzeit kennt. Das Gerät zählt ab dort lokal weiter. Es entsteht kein Dauerverkehr. Zur Korrektur einer Drift reicht ein erneuter Uhrzustand, etwa einmal pro Minute.

---

## 5. Lightroom-Plugin

Erweiterung um eine Meldung der aktuellen Quelle:

- Beim Wechsel des Fotos oder der Ansicht meldet das Plugin, aus welcher Sammlung bzw. welchem Ordner das aktive Foto stammt (Name und eindeutige Kennung bzw. Pfad).
- Neue Nachricht im Socket-Protokoll, z. B. `source` mit Typ (Sammlung/Ordner), Name und Kennung.
- Keine Logik im Plugin; die Zuordnung zu Jobs macht die App.

---

## 6. Desktop-App

### 6.1 Speicherung

SQLite im App-Datenordner statt JSON, weil Suche und Auswertungen über viele Einträge sonst mühsam werden. Ein Flutter-Paket wählen, das auf macOS und Windows läuft. Versionierte Migrationen von Anfang an vorsehen.

### 6.2 Datenmodell

**Job**

| Feld | Beschreibung |
| --- | --- |
| ID | eindeutig |
| Name | voller Name, z. B. „Hochzeit Müller, Potsdam“; bei neuen Jobs leer |
| Kürzel | optional, max. 10 Zeichen, für das Display; leer → Name gekürzt bzw. Datum/Uhrzeit |
| Kunde | optional |
| Farbe | optional, für Übersicht und Diagramme |
| Lightroom-Zuordnung | optional, eine oder mehrere Sammlungen/Ordner (Kennung) |
| Status | aktiv oder archiviert |
| Angelegt am | Zeitstempel |
| Zuletzt genutzt | Zeitstempel, für die Sortierung im Gerätemenü |

**Zeiteintrag**

| Feld | Beschreibung |
| --- | --- |
| ID | eindeutig |
| Job-ID | Verweis auf den Job |
| Start | Zeitstempel mit Zeitzone |
| Ende | Zeitstempel mit Zeitzone; leer, solange die Uhr läuft |
| Notiz | optional |
| Quelle | Gerät oder manuell |
| Bearbeitet | Flag, falls nachträglich geändert |

Gesamtzeiten werden aus den Einträgen berechnet, nicht gespeichert.

### 6.3 Menüleiste

- Zeigt die laufende Zeit und den Job neben dem Icon oder im Menü.
- Start/Stopp und Jobwechsel auch direkt aus dem Menü, mit den zuletzt genutzten Jobs.
- Nach dem Anlegen eines unbenannten Jobs erscheint eine dezente Aufforderung, ihn zu benennen.

### 6.4 Zeiterfassungs-Fenster

Eigener Bereich neben der Gerätekonfiguration.

- **Übersicht:** Stunden pro Job für Woche, Monat oder frei wählbaren Zeitraum; Summe gesamt
- **Jobs:** Liste mit Name, Kürzel, Kunde, Gesamtzeit, zuletzt genutzt; unbenannte Jobs oben hervorgehoben; Bearbeiten, Archivieren, Zusammenführen zweier Jobs
- **Einträge:** chronologische Liste je Job oder gesamt; Start, Ende und Notiz bearbeitbar; Einträge manuell anlegen und löschen
- **Archiv:** archivierte Jobs, weiterhin durchsuchbar, jederzeit reaktivierbar
- **Suche:** über Jobname, Kürzel, Kunde und Notiz, kombinierbar mit Zeitraum
- **Export:** CSV mit Job, Kunde, Start, Ende, Dauer, Notiz; Zeitraum und Jobs auswählbar
- **Lightroom-Zuordnung:** Beim Start eines Jobs kann die aktuelle Sammlung/der aktuelle Ordner mit einem Klick dem Job zugeordnet werden

### 6.5 Vorschlagslogik

1. Die App kennt die aktuelle Quelle aus dem Plugin.
2. Gibt es einen aktiven Job mit dieser Zuordnung, ist er der Vorschlag.
3. Sonst gibt es keinen Vorschlag; die Liste bleibt nach „zuletzt genutzt“ sortiert.

### 6.6 Leerlauferkennung (optional, abschaltbar)

- Gibt es eine einstellbare Zeit lang (Standard z. B. 10 Minuten) weder Eingaben am Gerät noch Änderungen in Lightroom, merkt sich die App den Beginn der Pause.
- Bei der nächsten Aktivität fragt sie: „Pause von X Minuten abziehen?“
- Die Uhr wird nie automatisch gestoppt, damit keine Zeit verloren geht.

---

## 7. Grenzfälle

| Fall | Verhalten |
| --- | --- |
| App wird beendet oder stürzt ab, während eine Uhr läuft | Beim nächsten Start fragt die App: weiterlaufen lassen, zum Zeitpunkt des Beendens stoppen oder Ende manuell setzen |
| Mac/PC geht in den Ruhezustand | Nach dem Aufwachen gleiche Frage wie bei der Leerlauferkennung |
| Gerät wird abgesteckt | Uhr läuft in der App weiter; nach dem Wiederverbinden übernimmt das Gerät den Zustand |
| Eintrag über Mitternacht | wird als ein Eintrag gespeichert; Auswertungen pro Tag teilen ihn rechnerisch auf |
| Zeitumstellung, Zeitzonenwechsel | Zeitstempel immer mit Zeitzone speichern, Dauer aus den absoluten Zeitpunkten berechnen |
| Job wird archiviert, während seine Uhr läuft | Uhr vorher stoppen oder Archivieren verhindern, mit Hinweis |
| Zwei Geräte verbunden | Es gibt weiterhin nur eine laufende Uhr; beide Geräte zeigen denselben Zustand |

---

## 8. Akzeptanzkriterien

- [ ] Langer Druck öffnet das Job-Menü aus jedem Zustand; ein normaler Klick löst ihn nie aus
- [ ] „Neuer Job“ legt einen unbenannten Job an, startet die Uhr und erscheint in der App unter „Unbenannt“
- [ ] Jobwechsel am Gerät stoppt den laufenden Job und startet den neuen in einem Schritt
- [ ] Die Zeit auf dem Gerät weicht nach einer Stunde höchstens wenige Sekunden von der App ab
- [ ] Reglerbedienung ist bei laufender Uhr unverändert
- [ ] Der Lightroom-Vorschlag erscheint, sobald eine zugeordnete Sammlung bearbeitet wird
- [ ] Übersicht, Archiv, Suche und CSV-Export funktionieren auf macOS und Windows
- [ ] Nach einem App-Absturz geht keine laufende Zeit verloren
- [ ] Ohne verbundene App zeigt das Gerät „Getrennt“ und erlaubt keine Aktion

---

## 9. Vorgeschlagene Reihenfolge

1. **Protokoll:** neue Nachrichtentypen festlegen (Reservierung bereits in Phase 1 der Basis)
2. **Desktop-App, Datenbasis:** Datenmodell, SQLite, Migrationen, Start/Stopp-Logik, Grenzfälle Absturz und Ruhezustand
3. **Firmware:** langer Druck mit Ring-Rückmeldung, Job-Menü, Zeitanzeige in der Ringlücke, neue Icons
4. **Desktop-App, Oberfläche:** Menüleiste, Zeiterfassungs-Fenster mit Übersicht, Jobs, Einträgen, Archiv, Suche, Export
5. **Plugin:** Meldung der aktuellen Quelle; Vorschlagslogik in der App
6. **Optional:** Leerlauferkennung, LED-Anzeige der laufenden Uhr
7. **Alltagstest** über mindestens eine Woche echter Aufträge

---

## 10. Offene Punkte

- [ ] Genaue Schwelle für den langen Druck (Alltagstest)
- [ ] Format der Zeitanzeige in der Ringlücke bei sehr langen Läufen (über 10 Stunden)
- [ ] Soll die Leerlauferkennung standardmäßig an oder aus sein?
- [ ] Rundung im Export (minutengenau, Viertelstunden) – als Einstellung oder fest?
- [ ] Sollen Jobs mehrere Lightroom-Sammlungen/Ordner gleichzeitig zugeordnet bekommen können?
