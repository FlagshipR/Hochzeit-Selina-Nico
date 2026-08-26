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

## Erreichbarkeit von außen (offener Punkt)

QuickConnect kann laut Synology **keine eigene Web-Station-Seite durchleiten** (nur DSM und File-Station-Freigabelinks). Für den Zugriff von der Hochzeitslocation aus ist ein **Cloudflare Tunnel** geplant (zeigt auf `localhost:8080`, kein Port-Forwarding am Router nötig) – **Stand letzter Bearbeitung noch nicht eingerichtet.**
