# nas-slideshow

Live-Fotowand für die Hochzeit von Selina & Nicolai (12.09.2026), selbst gehostet auf der heimischen Synology NAS statt bei einem Drittanbieter. Gäste laden Fotos ohne Login hoch, die Diashow läuft während der Feier auf einem Beamer und aktualisiert sich automatisch mit neuen Uploads.

Ursprünglich ein eigenes Repo (`Hochzeit-Slideshow-NAS`), am 26.08.2026 hierher als Unterordner zusammengeführt — es gab keinen Grund für ein separates Repo, und die erste (verworfene) Supabase-Version dieser Fotowand lag ohnehin schon in diesem Repo (`fotos.html`/`slideshow.html`, inzwischen entfernt).

## Funktionsweise

1. Gäste laden Fotos über Synology File Stations **"Dateianforderung"** hoch (kein DSM-Account nötig). Synology legt dabei automatisch einen Unterordner pro Gast an.
2. **Sync/Verarbeitung und Anzeige sind entkoppelt.** [`run-local.ps1`](run-local.ps1) läuft auf einem Windows-Laptop (siehe [Lokaler Modus](#lokaler-modus-run-localps1---sync--bildverarbeitung) unten) – dieser Laptop muss nicht am Veranstaltungsort stehen, er braucht nur Netzwerkzugriff auf `\\FLANAS\Hochzeitsfotos\GuestPhotos`. Er verarbeitet jedes neue Foto **genau einmal** (HEIC-Dekodierung, Dreh-Korrektur, Skalierung, Duplikat-Prüfung – Details unten) und schreibt das Ergebnis sowohl in seinen eigenen lokalen Cache als auch zurück auf die NAS (`Vorbereitet/`).
3. Für die **Anzeige** gibt es zwei gleichwertige Wege, die beide nur noch das fertig verarbeitete Ergebnis lesen (keine erneute HEIC-Dekodierung/Skalierung nötig):
   - **Lokal auf demselben Laptop:** `http://localhost:8090/slideshow.html`, liest aus dem lokalen Cache (`list.json`) – läuft auch ohne Verbindung zur NAS weiter.
   - **Von einem beliebigen anderen Gerät am Veranstaltungsort** (z. B. ein an den Fernseher angeschlossener **Fire TV Stick**, siehe [Erreichbarkeit von außen](#erreichbarkeit-von-außen)): `http://192.168.178.21:8080/slideshow.html` über die NAS Web Station, liest live über `list.php` aus `Vorbereitet/` (Details siehe [Alternative/Fallback](#alternativefallback-direkt-auf-der-nas-via-web-station)).
4. [`slideshow.html`](slideshow.html) zeigt die Fotos als Vollbild-Diashow mit Überblendung, Foto-Collagen (1-3 Bilder) und Ken-Burns-Effekt. Auswahl per globalem Shuffle-Bag (alle Fotos aller Gäste gemischt, kein Foto wiederholt sich bevor nicht alle anderen dran waren) statt strikter Gast-Rotation – einfacher und in der Praxis genauso gut durchmischt.

HEIC-Fotos (iPhone-Standardformat) werden **serverseitig einmalig** von `run-local.ps1` über den Windows-eigenen HEIF-Codec nach JPEG konvertiert (siehe [Bild-Pipeline](#bild-pipeline-run-localps1) unten) – nicht mehr client-seitig bei jedem Aufruf. `libheif-js` im Browser (`resolveUrl()` in `slideshow.html`/`demo.html`) ist nur noch ein Fallback für den Fall, dass eine Quelldatei aus irgendeinem Grund unverarbeitet (roh) landet.

## Lokaler Modus (`run-local.ps1`) - Sync & Bildverarbeitung

[`run-local.ps1`](run-local.ps1) synct `GuestPhotos` von der NAS, verarbeitet jedes Foto einmalig (siehe [Bild-Pipeline](#bild-pipeline-run-localps1)) und stellt Diashow + Fotos zusätzlich über einen lokalen Webserver bereit. Läuft rein in Windows PowerShell, keine Zusatz-Installation nötig. Dieser Laptop muss **nicht** am Veranstaltungsort stehen (siehe [Funktionsweise](#funktionsweise)) – er braucht nur Netzwerkzugriff auf die NAS, nicht auf den Anzeige-Ort.

```powershell
.\run-local.ps1                    # nur lokaler Zugriff (localhost)
.\run-local.ps1 -AllowRemote       # bindet auf 0.0.0.0 statt localhost, z.B. fuer Zugriff von anderen Geraeten im selben Netz
```

Dann im Browser: `http://localhost:8090/slideshow.html`

Was dabei passiert:
- Alle 12 Minuten (`-IntervalSeconds`) wird `GuestPhotos` neu durchsucht – dauerhaft, in einer Schleife, die nie von selbst endet (nicht nur einmal beim Start); unveränderte Dateien (Größe+Änderungsdatum bereits im Manifest bekannt) werden übersprungen statt erneut geprüft.
- Jede neue Datei wird per **SHA-256-Inhalts-Hash des verarbeiteten Ergebnisses** auf Duplikate geprüft (erkennt auch von verschiedenen Gästen hochgeladene identische Fotos, nicht nur gleiche Dateinamen) und nach `Downloads\Hochzeitsfotos-Cache\<Gast>\...` kopiert.
- Dateien, die vor weniger als 10 Sekunden geändert wurden (`-MinAgeSeconds`), werden übersprungen – Schutz gegen einen noch nicht fertig hochgeladenen Gast-Upload.
- **Nur eine Instanz gleichzeitig:** eine exklusive Sperrdatei (`.sync.lock` im Cache-Ordner) verhindert, dass z. B. ein Sleep/Wake-Zyklus oder ein versehentlicher Zweitstart zwei parallele Prozesse erzeugt, die sich beim Schreiben in die Quere kommen.
- `slideshow.html` liest im lokalen Modus aus `Downloads\Hochzeitsfotos-Cache\list.json` (lokal, nie live von der NAS) – einmal heruntergeladene Fotos laufen weiter, auch wenn die Verbindung zur NAS zwischendurch abbricht.

**Wichtig:** Die NAS (`\\FLANAS\Hochzeitsfotos\GuestPhotos`) muss für den *Sync* weiterhin erreichbar sein (Heimnetz oder VPN) – nur die *Anzeige* selbst braucht ab dann keine Netzwerkverbindung mehr zur NAS. Am besten den Sync-Laptop schon vor der Feier eine Weile mit Verbindung laufen lassen, damit Cache und `Vorbereitet/` gefüllt sind, bevor es drauf ankommt.

**Automatischer Neustart nach Schlaf/Ruhezustand ist nicht garantiert.** `Start-Sleep` pausiert beim Suspend einfach und läuft nach dem Aufwachen weiter, ohne Fehler – wirkt also unauffällig, kann aber dazu führen, dass der Prozess nach einem Systemschlaf stundenlang keinen Zyklus mehr fertig durchläuft, bevor die NAS-Verbindung wieder steht. Live beobachtet am 11./12.09.2026 (Laptop schlief über Nacht ein, Prozess blieb danach ~9h ohne weiteren Sync-Durchlauf hängen). Bei Verdacht: `Get-ScheduledTask -TaskName Hochzeit-Slideshow-Sync` und Prozessliste prüfen, im Zweifel `Stop-ScheduledTask` + `Start-ScheduledTask` für einen sauberen Neustart – **nicht** wiederholt `Stop`/`Start` kurz hintereinander, das kollidiert mit `RestartCount`/`RestartInterval` und kann kurzzeitig mehrere Prozesse gleichzeitig erzeugen (bevor die `.sync.lock`-Sperre greift).

Getestet am 09.09.2026 gegen die echten Gästefotos (361 synct, 2 Duplikate korrekt erkannt und übersprungen); Bild-Pipeline (Dreh-Korrektur, Skalierung, Dual-Write) und Duplikat-Bereinigung am 11./12.09.2026 nochmal erweitert und gegen reale Fehlerfälle gehärtet (siehe unten).

## Bild-Pipeline (`run-local.ps1`)

Jedes neue/geänderte Foto durchläuft beim Sync **einmalig** (nicht bei jedem Anzeige-Aufruf erneut):

1. **Dekodieren** über WPF (`System.Windows.Media.Imaging`, `Add-Type -AssemblyName PresentationCore`) – deckt neben JPEG/PNG auch **HEIC/HEIF** ab (Windows-eigener HEIF-Codec auf diesem Rechner installiert).
2. **EXIF-/HEIF-Ausrichtung anwenden:** viele Handys speichern Hochkant-Fotos als liegende Pixeldaten plus einem Dreh-Hinweis in den Metadaten. `JpegBitmapEncoder` übernimmt das beim Re-Encodieren **nicht automatisch** – ohne diesen Schritt landen Fotos seitlich/kopfüber im Ergebnis. Gelesen über `System.Photo.Orientation` (funktioniert für klassisches JPEG-EXIF und HEIF gleichermaßen), angewendet als `RotateTransform`/`ScaleTransform`.
3. **Skalieren** auf max. 1920px lange Kante (= Full-HD-Beamer-Auflösung; **nie hochskaliert**, kleinere Originale bleiben unverändert) – reduziert Dateigröße/Traffic spürbar, ohne auf dem Beamer sichtbaren Qualitätsverlust.
4. **Re-Encodieren** als JPEG, Qualität 85, in einen `MemoryStream` (noch nicht auf Platte).
5. **Duplikat-Hash (SHA-256) über das verarbeitete Ergebnis**, nicht über die Rohdatei (wichtiger Unterschied, siehe unten).
6. **Zweifach schreiben:** einmal in den lokalen Cache, einmal zurück auf die NAS nach `Vorbereitet/<Gast>/<Originalname>.jpg` (`Vorbereitet` liegt neben `GuestPhotos`, nicht darin) – damit auch der NAS-Web-Station-Pfad (Fire TV Stick etc.) das schlanke, fertige Bild ausliefert statt des Rohformats, **ohne die Verarbeitung ein zweites Mal auszuführen**. Ziel-Dateiname ist immer *kompletter Originalname + `.jpg`* (z. B. `IMG_0927.HEIC` → `IMG_0927.HEIC.jpg`), nicht die Endung ersetzt – dadurch automatisch kollisionsfrei ohne `_1`/`_2`-Zähllogik.

**Warum der Duplikat-Hash über das verarbeitete Ergebnis statt der Rohdatei läuft:** ursprünglich wurden nur die letzten 8 KB der Rohdatei vom Hash ausgeschlossen (wegen Motion-Photo-Trailern wie `PXL_*.MP.jpg`/`.MP_1.jpg`). Das hat zwei tatsächlich hochgeladene, inhaltsgleiche Fotos eines Gasts nicht erkannt, weil JPEG-/EXIF-Metadaten typischerweise am **Anfang** der Datei sitzen, nicht nur im Trailer. Nach Dekodieren+Neuencodieren bleibt nur noch reiner Bildinhalt übrig – der Hash darüber ist zuverlässiger. Serverseitig (NAS, PHP) gibt es einen zusätzlichen, unabhängigen Dedup-Lauf: [`sync-clean.php`](sync-clean.php) verschiebt bereits vor der Laptop-Verarbeitung erkannte reine Duplikate innerhalb `GuestPhotos` nach `GuestPhotos/@Duplikate_Entfernt/` (funktioniert auch, wenn der Sync-Laptop gerade nicht läuft).

**Bekannter Bug, behoben am 12.09.2026:** `list.json` bekam bei jeder *erneuten* Verarbeitung derselben Quelldatei (z. B. weil eine Drehung nachträglich korrigiert wurde) einen zusätzlichen Eintrag angehängt statt den alten zu ersetzen – der alte Eintrag zeigte damit auf eine längst überschriebene, teils veraltete/falsch gedrehte Zwischenversion. Betroffene Fotos erschienen dadurch in der Diashow öfter als vorgesehen; beim Kindheitsfoto-Batch für Selina betraf das zeitweise 463 von 503 Einträgen (list.json war über mehrere Namenskonventions-Wechsel hinweg nie bereinigt worden). Fix: `$urlIndex` in `run-local.ps1` indiziert jede URL auf ihre Position in der Liste, ein erneut verarbeitetes Foto ersetzt jetzt seinen bestehenden Eintrag statt einen weiteren anzuhängen.

### Automatischer Start (`install-autostart.ps1`)

`run-local.ps1` läuft nur, solange sein PowerShell-Fenster offen ist – kein Hintergrunddienst von Haus aus. [`install-autostart.ps1`](install-autostart.ps1) richtet dafür eine Windows-Aufgabenplanung ein, die es bei jedem Login automatisch versteckt im Hintergrund startet:

```powershell
.\install-autostart.ps1    # einmalig einrichten, startet auch gleich
.\uninstall-autostart.ps1  # rueckgaengig machen
```

- Läuft auch im Akkubetrieb weiter, kein Zeitlimit (Task Scheduler würde eine Dauerschleife sonst nach 3 Tagen killen), startet bei Absturz automatisch neu (3x, 1 Min. Abstand).
- Ausgabe landet in `Downloads\Hochzeitsfotos-Sync.log` statt in einem sichtbaren Fenster.
- Named Task: `Hochzeit-Slideshow-Sync` (Aufgabenplanung → Aufgabenplanungsbibliothek, falls manuell nachschauen).

**Bekannte Randbedingung:** Ein `Stop-ScheduledTask` gefolgt von einem sofortigen Neustart kann kurz mit "Port bereits belegt" fehlschlagen, falls der vorherige Server-Prozess den Port noch nicht freigegeben hat – `run-local.ps1` versucht das Binden seit dem 09.09.2026 automatisch bis zu 5x mit 2s Abstand, das behebt den Normalfall von selbst.

### Alternative/Fallback: direkt auf der NAS via Web Station

Falls der lokale Modus am Tag selbst aus irgendeinem Grund nicht geht, funktioniert der ursprüngliche Ansatz weiterhin: [`list.php`](list.php) durchsucht `GuestPhotos/` live und liefert JSON, `slideshow.html` kann das per `LIST_URL` auch direkt abfragen (aktuell auf `cache/list.json` für den lokalen Modus umgestellt – für diesen Fallback müsste das temporär zurückgeändert werden). Ohne lokalen Cache, dafür ohne Sync-Skript. Setup siehe unten.

## Deployment – wichtig: drei verschiedene Orte, kein Auto-Sync

Dieser Ordner ist die **Quelle** (versioniert, hier wird entwickelt). Es gibt daneben zwei weitere Kopien, die **nicht automatisch** damit synchron sind:

| Ort | Zweck |
|---|---|
| `github.com/FlagshipR/Hochzeit-Selina-Nico/nas-slideshow` (dieser Ordner) | Quelle/Historie |
| `C:\Users\flach\Documents\Git Projects\Hochzeit-Selina-Nico\nas-slideshow` (lokal) | Arbeitskopie; das Gesamtrepo synct separat via Synology Drive nach `/volume1/homes/Nicolai/Drive/Backup/...` – **das ist nicht der Deploy-Ordner** |
| `/volume1/Hochzeitsfotos/` auf der NAS (`\\FLANAS\Hochzeitsfotos`) | **Live-Kopie**, die Web Station tatsächlich ausliefert |

**Nach jeder Änderung müssen `list.php` und `slideshow.html` manuell nach `/volume1/Hochzeitsfotos/` kopiert werden** (z. B. per Kopieren über das gemappte Laufwerk `\\FLANAS\Hochzeitsfotos`, oder via File Station). Es gibt keine CI/Automatik dafür.

Der Ordner `/volume1/Hochzeitsfotos/` muss außerdem `GuestPhotos/` (Ziel der Dateianforderung) enthalten – `list.php` erwartet ihn im selben Verzeichnis.

**Live passiert (12.09.2026):** ein `slideshow.html`-Fix (Bild-Vorladen, Gesichter-Zuschnitt) wurde committed, aber der manuelle Kopierschritt vergessen – der Fire-TV-Stick-Pfad lief dadurch über einen Tag mit einer veralteten Version, ohne dass das an den Fotos selbst auffiel (`list.php` blieb unverändert, nur `slideshow.html` war stale). Bei jeder Änderung an `slideshow.html`/`list.php` explizit gegenprüfen (z. B. `diff` gegen die NAS-Kopie), nicht nur gegen den Git-Stand.

## NAS-Setup (Synology DS218+, DSM 7.2/7.3)

1. **Web Station** installieren (Paket-Zentrum), inkl. eines aktuellen PHP-Profils (8.x – nicht das mitgelieferte Default-Profil PHP 5.6 verwenden, das ist seit 2019 ohne Sicherheitsupdates).
2. Web Station → Webdienstportal → Erstellen → **Virtueller Host**:
   - Portaltyp: **Portbasiert** (kein Hostname nötig), z. B. HTTP Port `8080`
   - Dokument-Root: `Hochzeitsfotos`
   - Skript-Spracheinstellungen: **PHP**, aktuelles Profil auswählen
3. `list.php` + `slideshow.html` nach `/volume1/Hochzeitsfotos/` kopieren.
4. Lokal testen: `http://<NAS-lokale-IP>:8080/slideshow.html`. Falls Fotos nicht erscheinen: Berechtigungen von `GuestPhotos` prüfen (Gruppe "http" braucht Lesezugriff).

Bestätigter Stand: Portbasierter virtueller Host, HTTP Port `8080`, Dokument-Root `Hochzeitsfotos`, PHP-Profil 8.0, Nginx-Backend, 60s-Timeouts. Lokale URL (nur im Heimnetz erreichbar): `http://192.168.178.21:8080/slideshow.html`.

## Erreichbarkeit von außen

**Seit dem lokalen Modus (`run-local.ps1`) reduziert sich das auf: der Beamer-Laptop selbst braucht Zugriff auf `\\FLANAS\Hochzeitsfotos\GuestPhotos` (SMB) für den Sync** – nicht mehr auf Web Station/Port 8080, die Anzeige läuft ja lokal. VPN bleibt trotzdem nötig, weil SMB genau wie Web Station nur im Heimnetz direkt erreichbar ist. Der Rest dieses Abschnitts (WireGuard-Entscheidung) gilt weiterhin, nur der Zweck hat sich leicht verschoben – von "Zugriff auf die Diashow-Seite" zu "Zugriff auf den Foto-Ordner".


QuickConnect kann laut Synology **keine eigene Web-Station-Seite durchleiten** (nur DSM und File-Station-Freigabelinks) – am 26.08.2026 auch praktisch bestätigt: Aufruf von `http://FLA-DX2ARN3-NAS.quickconnect.to:8080/slideshow.html` über mobile Daten schlägt fehl. Ein Cloudflare Tunnel wäre eine Option gewesen, braucht für eine stabile Adresse aber eine eigene Domain (~10€/Jahr) – verworfen zugunsten von:

**Entscheidung: WireGuard-VPN statt direkter Portfreigabe.** Der Upload-Link muss von beliebigen Gästehandys erreichbar sein (bleibt über QuickConnect/Dateianforderung), aber die Slideshow-*Anzeige* braucht nur einem einzigen kontrollierten Gerät (dem Beamer-Laptop) Zugriff von außen – dafür ist ein VPN sicherer als ein offener Port: WireGuard antwortet nicht auf Anfragen ohne gültigen Schlüssel (für Portscans praktisch unsichtbar), während ein offener Webserver-Port routinemäßig von automatisierten Scannern gefunden und gegen bekannte Schwachstellen getestet wird. Ausschlaggebend: Auf derselben NAS liegt auch `GuestPhotos` mit privaten Gästefotos.

Stand: **fertig eingerichtet und erfolgreich getestet** (11.09.2026, über mobilen Hotspot – nicht Heim-WLAN).

**WireGuard-Host: NAS oder FritzBox, beides funktional gleichwertig.** Entscheidend ist nur, dass der VPN-Client danach das Heimnetz erreicht (insbesondere `192.168.178.21:8080`) – ob der WireGuard-Server dafür auf der NAS oder auf der FritzBox läuft, ist aus Sicht des Clients ununterscheidbar. Tatsächlich genutzt wurde am Ende eine von der FritzBox exportierte Konfigurationsdatei (`FB_VPN_Nico_FireTV.conf`).

### Fire TV Stick als Anzeige-Gerät

Der Fire TV Stick zeigt die Diashow über einen Browser, verbunden per WireGuard-VPN zum Heimnetz – der Sync-Laptop selbst bleibt zuhause.

1. **Entwickleroptionen aktivieren:** Einstellungen → Mein Fire TV → Info → mehrfach auf die Build-Nummer klicken. Danach erscheint der Menüpunkt **Entwickleroptionen** (eigener Menüpunkt unter "Mein Fire TV", nicht unter "Info") → **ADB-Debugging** aktivieren.
2. **IP-Adresse notieren:** Einstellungen → Mein Fire TV → **Netzwerk** (nicht "Info") → zeigt die aktuelle lokale IP.
3. **Per ADB verbinden** (vom PC, im selben lokalen Netz wie der Stick – **vor** VPN-Aktivierung, da VPN das lokale Netz sonst ersetzt): `adb connect <Fire-TV-IP>:5555`. Auf dem Fire-TV-Bildschirm erscheint eine Autorisierungs-Abfrage, die dort bestätigt werden muss (nicht automatisch sichtbar – ggf. zur Startseite wechseln, um sie zu sehen).
4. **WireGuard-APK sideloaden:** `adb install <pfad-zur-apk>` (offizielle WireGuard-APK, vor Nutzung mit `Start-MpScan -ScanPath ... -ScanType CustomScan` o. ä. geprüft). Fire TV OS hat keinen Play-Store-Zugriff auf die reguläre WireGuard-App, daher Sideload nötig.
5. **VPN-Config importieren:** `.conf`-Datei auf den Stick übertragen (z. B. per ADB push oder Cloud-Ordner-App) und in der WireGuard-App importieren. **Bekannter Stolperstein:** Import kann mit "ungültiger Name" fehlschlagen, wenn der Dateiname Zeichen enthält, die WireGuard als Tunnel-Namen nicht akzeptiert – Datei ggf. umbenennen (nur Buchstaben/Zahlen/`-`/`_`).
6. Tunnel aktivieren, danach normalen Browser auf dem Stick öffnen und `http://192.168.178.21:8080/slideshow.html` aufrufen.
7. ADB-Debugging kann danach wieder deaktiviert werden, ohne dass die installierte WireGuard-App dadurch entfernt wird – ADB ist nur der Installationsweg, keine Laufzeit-Abhängigkeit.

Verworfene Alternative (dokumentiert falls sich die Abwägung nochmal ändert): Synology DDNS (kostenlos, z. B. `xyz.synology.me`) + direkte Portfreigabe auf 8080 – einfacher (kein VPN-Client nötig), aber der Web-Station-Port läge über Wochen offen im Internet statt nur ein VPN-Endpunkt.
