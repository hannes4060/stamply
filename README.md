# Stamply

macOS-App (SwiftUI), die Text- und/oder Logo-Wasserzeichen stapelweise auf Fotos setzt.

- Formate: **JPG, HEIC**, außerdem PNG. Das Format bleibt erhalten (HEIC → HEIC).
- Fotos oder ganze Ordner per Drag & Drop hinzufügen (Unterordner werden mitgenommen).
- Ergebnisse landen im gewählten Ausgabeordner, **Originale werden nie verändert**.
- Text (Schrift, Fett, Größe, Farbe, Schatten), Logo (PNG mit Transparenz), oder beides.
- 9 Positionen mit Randabstand oder Kachelmuster über das ganze Bild (Abstand, Winkel).
- Deckkraft, Exportqualität, Namenszusatz (z. B. `_wm`).
- EXIF-Daten bleiben erhalten, GPS-Standort wird optional entfernt, Datei-Datum wird übernommen.
- Größen beziehen sich auf die kürzere Bildseite, damit Hoch- und Querformat gleich aussehen.
- Verarbeitung parallel im Hintergrund, abbrechbar. Einstellungen werden gespeichert.

## Voraussetzungen

- macOS 13 (Ventura) oder neuer
- Xcode **oder** nur die Command Line Tools: `xcode-select --install`

## Bauen

```bash
cd Stamply
./build-app.sh
cp -R build/Stamply.app /Applications/
```

Das Skript ruft `swiftc` direkt auf und braucht den Swift-Paketmanager nicht.
Zum schnellen Testen ohne App-Bundle geht auch `swift run` (benötigt SwiftPM).

Alternativ in Xcode: `Package.swift` öffnen und auf *Run* klicken.

Ein eigenes Icon: `icon.icns` neben `build-app.sh` legen, dann neu bauen.

## Hinweise

- Die App ist nur ad-hoc signiert. Auf dem Mac, auf dem sie gebaut wurde, startet sie direkt.
  Auf andere Macs kopiert: beim ersten Start Rechtsklick → *Öffnen*.
- iPhone-HEICs mit HDR-Zusatzdaten (Gain Map) werden als normales HEIC gespeichert,
  die HDR-Helligkeitsinformation geht dabei verloren. Farbraum (Display P3) bleibt erhalten.
- Die EXIF-Ausrichtung wird beim Verarbeiten in die Pixel übernommen, das Ergebnis steht immer aufrecht.

## Aufbau

| Datei | Inhalt |
|---|---|
| `StamplyApp.swift` | App-Einstieg, Menü |
| `ContentView.swift` | Oberfläche: Dateiliste, Einstellungen, Startleiste |
| `AppModel.swift` | Zustand, Dateiauswahl, Batch-Verarbeitung, Speichern der Einstellungen |
| `WatermarkRenderer.swift` | Lesen, Zeichnen und Schreiben der Bilder (ImageIO, Core Graphics, Core Text) |
| `Models.swift` | Einstellungen und Datentypen |
