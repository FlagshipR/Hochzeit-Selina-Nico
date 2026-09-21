# wedding-guest-upload

Zweite, eigenständige Upload-Lösung für Hochzeitsfotos – anders als [`nas-slideshow`](../nas-slideshow) **keine Diashow, kein Sync-Laptop**, nur zuverlässige Dateiablage. Hintergrund: Gäste sind inzwischen wieder zu Hause und sollen von dort noch Fotos/Videos nachreichen können, die sie selbst gemacht haben.

## Warum nicht wieder die Synology-Dateianforderung?

Bei der Hochzeit gab es wiederholt Abbrüche/Schwierigkeiten beim Hochladen. Wahrscheinlichste Ursache: der Upload-Link lief über **QuickConnects Relay-Betrieb**, der den Durchsatz spürbar drosselt (Traffic wird über Synologys eigene Server geleitet statt direkt) – bei großen Videos über eine wacklige Verbindung praktisch ein garantierter Timeout. Dazu kommt: die Dateianforderung überträgt eine Datei als Ganzes – bricht die Verbindung mittendrin ab, fängt der Upload bei null wieder an.

Diese Lösung hier begegnet beidem:
- **Chunked Upload mit Wiederaufnahme** (`upload.php` + `upload.js`, keine externe Bibliothek): jede Datei wird in 5-MB-Stücken übertragen. Bricht die Verbindung ab, wird beim nächsten Versuch nur der fehlende Rest nachgeladen – nicht die ganze Datei neu. Die Wiederaufnahme braucht keinen gespeicherten Zustand im Browser: die ID einer Datei wird deterministisch aus Gastname+Dateiname+Größe gebildet, wählt ein Gast nach einem Tab-Neuladen dieselben Dateien erneut aus, erkennt der Server automatisch den bisherigen Fortschritt.
- **Direkter Netzwerkweg statt QuickConnect-Relay** (siehe NAS-Setup unten) – Reverse-Proxy auf einen eigenen, schmalen Web-Station-Host statt einer Portfreigabe auf DSM selbst.
- **Keine Kompression/Skalierung, an keiner Stelle** – Dateien landen byte-identisch zum Original.

## Dateien

- `index.html` / `upload.js` – Frontend: Namensfeld, Drag&Drop oder Dateiauswahl, Fortschritt pro Datei, automatischer Retry mit Backoff.
- `upload.php` – Backend: nimmt Chunks entgegen, setzt sie zusammen, keine Bildbearbeitung.
- `welcome.html` – Landing-Page vor dem Upload-Formular (Diashow, Musik, Drohnenvideo).
- `galerie.html` / `galerie.js` / `photos.php` / `image.php` – "Tauschhandel": personalisierte Foto-Galerie pro Gast, siehe eigener Abschnitt unten.

## NAS-Setup

### 1. Zielordner & Berechtigungen

Uploads landen direkt in Nicolais persönlicher Photos-Bibliothek, nicht in einem separaten Freigabeordner:

```
/volume1/homes/Nicolai/Photos/Moments/Selina/20260912_Hochzeit_Traumfrau/wedding-guest-upload/<Gastname>/<Originaldateiname>
```

Das liegt **außerhalb** dessen, was der Web-Station-Dienst-Account standardmäßig beschreiben darf. In DSM freigeben:

1. **File Station** → zum Ordner `.../20260912_Hochzeit_Traumfrau/` navigieren (bei Bedarf `wedding-guest-upload` als Unterordner anlegen, `upload.php` legt ihn sonst selbst an, sofern die Berechtigung schon passt).
2. Ordner rechtsklicken → **Eigenschaften** → **Berechtigung**.
3. Dem Benutzer/der Gruppe, unter der Web Station/PHP läuft (i. d. R. `http` bzw. der in Web Station hinterlegte PHP-Benutzer), **Lesen+Schreiben** auf genau diesen Unterordner geben – nicht auf das ganze `homes/Nicolai`-Verzeichnis.
4. `.tmp`-Unterordner (Zwischenspeicher für unvollständige Uploads) legt `upload.php` selbst an – gleiche Berechtigung reicht dafür aus.

### 2. Eigener Web-Station-Host

Neuer, von `nas-slideshow` getrennter virtueller Host (Web Station → Webdienstportal → Erstellen → Virtueller Host), Dokument-Root = dieser Ordner (`wedding-guest-upload`), PHP-Profil 8.x, eigener interner Port.

**PHP-Einstellungen prüfen** (Web Station → PHP-Einstellungen → Erweiterte Einstellungen → Core): `post_max_size` und `upload_max_filesize` auf mindestens 10 MB setzen (Chunk-Größe ist 5 MB, etwas Puffer einplanen) – Standardwerte können knapper sein.

### 3. Erreichbarkeit ohne QuickConnect-Relay

Damit Gäste von zu Hause aus nicht über den gedrosselten Relay laufen:

1. Kostenlose **Synology-DDNS**-Adresse einrichten (Systemsteuerung → Externer Zugriff → DDNS) – eigener Hostname, getrennt von einem eventuell für DSM-Login genutzten.
2. **Reverse-Proxy-Regel** (Systemsteuerung → Anmeldeportal → Erweitert → Reverse-Proxy): Quelle `https://<hostname>:443` → Ziel `http://localhost:<interner Port dieses Hosts>`. Wichtig: **nicht** auf den DSM-Verwaltungsport (5001) zeigen – dieser Host hier ist strukturell von DSMs Login getrennt, das soll so bleiben.
3. Kostenloses Let's-Encrypt-Zertifikat für den neuen Hostnamen (Systemsteuerung → Sicherheit → Zertifikat).
4. An der **FritzBox**: Portfreigabe WAN 443 → NAS-IP:443.

### 4. Nach dem Sammelzeitraum wieder schließen

Wie beim alten Dateianforderungs-Link: die Portfreigabe an der FritzBox nur so lange aktiv lassen, wie tatsächlich noch Gäste hochladen sollen, danach deaktivieren – reduziert die Zeit, in der überhaupt etwas vom Internet aus erreichbar ist.

### 5. Personen-Galerie ("Tauschhandel")

Jeder Gast bekommt einen personalisierten Link (`galerie.html?g=<slug>`, z. B. `?g=julia`) und sieht dort nur Fotos, auf denen er/sie laut Zuordnung zu sehen ist. Fotos werden **nie kopiert** – `image.php` streamt sie live direkt vom NAS-Originalpfad.

**Wie die Zuordnung funktioniert – zwei Schichten:**
1. **`gallery-data/lists/<slug>.txt`** – eine Klartext-Liste pro Person, ein NAS-Pfad pro Zeile. **Das ist die von Hand gepflegte Quelle der Wahrheit** – Zeile löschen = Foto raus, Zeile ergänzen = Foto rein. Erste Zeile optional `# Name: <Anzeigename>` für einen Namen, der vom Dateinamen abweicht (z. B. Umlaute); Zeilen mit `#` werden sonst ignoriert.
2. **`gallery-data/person-photos.json`** – wird aus den `.txt`-Listen generiert (`regenerate-gallery-data.ps1`, siehe unten) und ist die Datei, die `photos.php`/`image.php` tatsächlich lesen. **Nicht von Hand bearbeiten** – nach jeder Listen-Änderung das Skript neu laufen lassen.

Die ursprüngliche automatische Zuordnung kam aus Synology Photos' Gesichtserkennung (siehe `reference_synology_photos_api` in Claudes Memory-System) – die Listen waren der Ausgangspunkt, sind aber jetzt manuell kuratierbar/korrigierbar, unabhängig von der Automatik.

**NAS-Freigabe (zusätzlich zu Abschnitt 1 oben):** der Web-Station-Dienst-Account braucht **Lesezugriff** auf alle Ordner, aus denen Fotos stammen (mind. `.../20260912_Hochzeit_Traumfrau/Hochzeitsfotos/`, `.../Hochzeitbilder Fotobox/`, `.../wedding-guest-upload/`) – bisher hatte er dort nur Schreibzugriff auf den Upload-Zielordner. Gleiches Vorgehen wie in Abschnitt 1: File Station → Eigenschaften → Berechtigung → Lesen für den PHP-Benutzer.

**`gallery-data/person-photos.json` NICHT in den Web-Dokument-Root legen** – die Datei enthält volle NAS-Pfade aller zugeordneten Personen, das wäre ein Informationsleck an jeden mit dem Basis-Link. Sie muss außerhalb des von Web Station servierten Bereichs liegen; `photos.php`/`image.php` lesen sie über einen absoluten Dateisystempfad (siehe `DATA_FILE`-Konstante in beiden Dateien).

## Deployment

Wie bei `nas-slideshow`: **kein CI**, geänderte Dateien müssen manuell auf die NAS kopiert werden (z. B. über `\\FLANAS\...`):
- `index.html`/`upload.js`/`upload.php`/`welcome.html` → Dokument-Root des Web-Station-Hosts.
- `galerie.html`/`galerie.js`/`photos.php`/`image.php` → ebenfalls Dokument-Root.
- `gallery-data/person-photos.json` (nach `regenerate-gallery-data.ps1`) → **außerhalb** des Dokument-Roots, an den Pfad aus der `DATA_FILE`-Konstante (siehe Abschnitt 5).

## Lokale Vorschau (nur Frontend, kein Upload-Test möglich)

```powershell
python -m http.server 8091 --directory wedding-guest-upload
```

Zeigt Oberfläche und Interaktion, aber `upload.php` läuft ohne PHP-Interpreter nicht – für einen echten Upload-Test muss auf der NAS getestet werden.
