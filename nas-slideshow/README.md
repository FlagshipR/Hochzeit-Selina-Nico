# nas-slideshow

Live-Fotowand für die Hochzeit von Selina & Nicolai (12.09.2026), selbst gehostet auf der heimischen Synology NAS statt bei einem Drittanbieter. Gäste laden Fotos ohne Login hoch, die Diashow läuft während der Feier auf einem Beamer und aktualisiert sich automatisch mit neuen Uploads.

Ursprünglich ein eigenes Repo (`Hochzeit-Slideshow-NAS`), am 26.08.2026 hierher als Unterordner zusammengeführt — es gab keinen Grund für ein separates Repo, und die erste (verworfene) Supabase-Version dieser Fotowand lag ohnehin schon in diesem Repo (`fotos.html`/`slideshow.html`, inzwischen entfernt).

## Funktionsweise

1. Gäste laden Fotos über Synology File Stations **"Dateianforderung"** hoch (kein DSM-Account nötig). Synology legt dabei automatisch einen Unterordner pro Gast an.
2. [`list.php`](list.php) durchsucht den Zielordner `GuestPhotos/` rekursiv (alle Unterordner) und liefert alle gefundenen Bilder als JSON.
3. [`slideshow.html`](slideshow.html) fragt `list.php` alle 12 Sekunden ab und zeigt die Fotos als Vollbild-Diashow mit Überblendung – neue Uploads erscheinen live, ohne dass jemand die Seite neu laden muss.

Bewusst nicht unterstützt: HEIC-Fotos (typisch bei iPhones, ohne Konvertierung nicht direkt aus dem Browser anzeigbar) werden beim Abspielen übersprungen, bleiben aber im Ordner erhalten.

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

QuickConnect kann laut Synology **keine eigene Web-Station-Seite durchleiten** (nur DSM und File-Station-Freigabelinks) – am 26.08.2026 auch praktisch bestätigt: Aufruf von `http://FLA-DX2ARN3-NAS.quickconnect.to:8080/slideshow.html` über mobile Daten schlägt fehl. Ein Cloudflare Tunnel wäre eine Option gewesen, braucht für eine stabile Adresse aber eine eigene Domain (~10€/Jahr) – verworfen zugunsten von:

**Entscheidung: WireGuard-VPN statt direkter Portfreigabe.** Der Upload-Link muss von beliebigen Gästehandys erreichbar sein (bleibt über QuickConnect/Dateianforderung), aber die Slideshow-*Anzeige* braucht nur einem einzigen kontrollierten Gerät (dem Beamer-Laptop) Zugriff von außen – dafür ist ein VPN sicherer als ein offener Port: WireGuard antwortet nicht auf Anfragen ohne gültigen Schlüssel (für Portscans praktisch unsichtbar), während ein offener Webserver-Port routinemäßig von automatisierten Scannern gefunden und gegen bekannte Schwachstellen getestet wird. Ausschlaggebend: Auf derselben NAS liegt auch `GuestPhotos` mit privaten Gästefotos.

Stand:
- WireGuard auf der NAS aktiviert, VPN-Port am Router freigegeben ✓
- **Noch offen:** Client-Profil für den Beamer-Laptop exportieren (VPN Server → WireGuard → Peer hinzufügen → `.conf` exportieren), [WireGuard-Client](https://www.wireguard.com/install/) installieren, Verbindung von außerhalb testen (mobiler Hotspot, nicht Heim-WLAN!)
- Danach bei aktiver VPN-Verbindung ganz normal `http://192.168.178.21:8080/slideshow.html` aufrufen

Verworfene Alternative (dokumentiert falls sich die Abwägung nochmal ändert): Synology DDNS (kostenlos, z. B. `xyz.synology.me`) + direkte Portfreigabe auf 8080 – am Hochzeitstag einfacher (kein VPN-Client nötig), aber der Web-Station-Port läge über Wochen offen im Internet statt nur ein VPN-Endpunkt.
