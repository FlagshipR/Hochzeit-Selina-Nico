# nas-slideshow

Live-Fotowand für die Hochzeit von Selina & Nicolai (12.09.2026), selbst gehostet auf der heimischen Synology NAS statt bei einem Drittanbieter. Gäste laden Fotos ohne Login hoch, die Diashow läuft während der Feier auf einem Beamer und aktualisiert sich automatisch mit neuen Uploads.

Ursprünglich ein eigenes Repo (`Hochzeit-Slideshow-NAS`), am 26.08.2026 hierher als Unterordner zusammengeführt — es gab keinen Grund für ein separates Repo, und die erste (verworfene) Supabase-Version dieser Fotowand lag ohnehin schon in diesem Repo (`fotos.html`/`slideshow.html`, inzwischen entfernt).

## Funktionsweise

1. Gäste laden Fotos über Synology File Stations **"Dateianforderung"** hoch (kein DSM-Account nötig). Synology legt dabei automatisch einen Unterordner pro Gast an.
2. Der Beamer-Laptop läuft **komplett lokal offline** (siehe [Lokaler Modus](#lokaler-modus-run-localps1---primärer-weg) unten) statt live gegen die NAS zu rendern – robust gegen VPN-/Netzwerk-Aussetzer während der Feier.
3. [`slideshow.html`](slideshow.html) zeigt die Fotos als Vollbild-Diashow mit Überblendung, Foto-Collagen (1-3 Bilder) und Ken-Burns-Effekt. Reihum ein Foto pro Gast statt streng chronologisch, jeder Gast in zufälliger statt chronologischer Reihenfolge – niemand blockiert mit einem Upload-Schwall die anderen, keine Bilder-Blöcke.

HEIC-Fotos (iPhone-Standardformat) werden client-seitig im Browser per `libheif-js` decodiert (siehe `resolveUrl()` in `slideshow.html`/`demo.html`).

## Lokaler Modus (`run-local.ps1`) - primärer Weg

[`run-local.ps1`](run-local.ps1) synct `GuestPhotos` von der NAS auf die lokale Platte (Downloads-Ordner) und stellt Diashow + Fotos über einen lokalen Webserver bereit. Läuft rein in Windows PowerShell, keine Zusatz-Installation nötig - wichtig fürs Deployment auf dem (evtl. fremden/geliehenen) Beamer-Laptop am Hochzeitstag.

```powershell
.\run-local.ps1
```

Dann im Browser: `http://localhost:8090/slideshow.html`

Was dabei passiert:
- Alle 12 Minuten (`-IntervalSeconds`) wird `GuestPhotos` neu durchsucht – dauerhaft, in einer Schleife, die nie von selbst endet (nicht nur einmal beim Start); unveränderte Dateien (Größe+Änderungsdatum bereits im Manifest bekannt) werden übersprungen statt erneut geprüft.
- Jede neue Datei wird per **SHA-256-Inhalts-Hash** auf Duplikate geprüft (erkennt auch von verschiedenen Gästen hochgeladene identische Fotos, nicht nur gleiche Dateinamen) und nach `Downloads\Hochzeitsfotos-Cache\<Gast>\...` kopiert.
- Dateien, die vor weniger als 10 Sekunden geändert wurden (`-MinAgeSeconds`), werden übersprungen – Schutz gegen einen noch nicht fertig hochgeladenen Gast-Upload.
- `slideshow.html` liest nur noch aus `Downloads\Hochzeitsfotos-Cache\list.json` (lokal, nie live von der NAS) – einmal heruntergeladene Fotos laufen weiter, auch wenn VPN/Verbindung zur NAS zwischendurch abbricht.

**Wichtig:** Die NAS (`\\FLANAS\Hochzeitsfotos\GuestPhotos`) muss für den *Sync* weiterhin erreichbar sein (Heimnetz oder VPN, siehe unten) – nur die *Anzeige* selbst braucht ab dann keine Netzwerkverbindung mehr zur NAS. Am besten den Laptop schon vor der Feier eine Weile mit Verbindung laufen lassen, damit der Cache gefüllt ist, bevor es drauf ankommt.

Getestet am 09.09.2026 gegen die echten Gästefotos (361 synct, 2 Duplikate korrekt erkannt und übersprungen).

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

Stand:
- WireGuard auf der NAS aktiviert, VPN-Port am Router freigegeben ✓
- **Noch offen:** Client-Profil für den Beamer-Laptop exportieren (VPN Server → WireGuard → Peer hinzufügen → `.conf` exportieren), [WireGuard-Client](https://www.wireguard.com/install/) installieren, Verbindung von außerhalb testen (mobiler Hotspot, nicht Heim-WLAN!)
- Danach bei aktiver VPN-Verbindung ganz normal `http://192.168.178.21:8080/slideshow.html` aufrufen

Verworfene Alternative (dokumentiert falls sich die Abwägung nochmal ändert): Synology DDNS (kostenlos, z. B. `xyz.synology.me`) + direkte Portfreigabe auf 8080 – am Hochzeitstag einfacher (kein VPN-Client nötig), aber der Web-Station-Port läge über Wochen offen im Internet statt nur ein VPN-Endpunkt.
