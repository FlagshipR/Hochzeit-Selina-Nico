<?php
declare(strict_types=1);

// upload.php — nimmt Foto-/Video-Chunks von Gaesten entgegen und setzt sie zu
// vollstaendigen Dateien zusammen. Kein Login noetig (wie die alte
// Dateianforderung), aber im Unterschied dazu: pro Datei einzeln und mit
// Wiederaufnahme nach Verbindungsabbruch - offset-basiertes Schreiben statt
// eines festen Chunk-Protokolls, siehe README fuer den Hintergrund (die
// Dateianforderung hatte genau daran gehapert: ein Abbruch bei einem grossen
// Video warf die ganze Datei weg, nicht nur den Rest).
//
// WICHTIG: Ziel-Ordner liegt bewusst NICHT neben diesem Skript, sondern in
// Nicolais privater Photos-Bibliothek - der Web-Station-Dienst-Account
// braucht dafuer eine gezielt auf genau diesen Unterordner freigegebene
// Schreibberechtigung (siehe README, Abschnitt "NAS-Setup").
//
// Bewusst ohne jede Bildbearbeitung: Chunks landen byte-genau wie
// hochgeladen in der Zieldatei - keine Kompression, keine Skalierung.

const TARGET_BASE_DIR = '/volume1/homes/Nicolai/Photos/Moments/Selina/20260912_Hochzeit_Traumfrau/wedding-guest-upload';
const TMP_DIR = TARGET_BASE_DIR . '/.tmp';
const CHUNK_SIZE = 5 * 1024 * 1024; // 5 MB - muss mit upload.js uebereinstimmen
const ALLOWED_EXT = ['jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'gif', 'mp4', 'mov', 'm4v', '3gp'];
const MAX_NAME_LEN = 100;

header('Content-Type: application/json; charset=utf-8');

function fail(int $code, string $msg): void {
    http_response_code($code);
    echo json_encode(['error' => $msg]);
    exit;
}

// Nur druckbare Zeichen ohne Pfad-Sonderzeichen erlauben - verhindert Path
// Traversal (../) ueber Gast-Namen oder Dateiname, unabhaengig davon, dass
// weiter unten zusaetzlich mit realpath() gegen TARGET_BASE_DIR geprueft wird
// (Verteidigung in mehreren Schichten, wie schon in list.php/sync-clean.php
// im Slideshow-Projekt).
function sanitizeSegment(string $s): string {
    $s = preg_replace('/[\/\\\\\x00-\x1f]/', '', $s) ?? '';
    $s = trim($s);
    // "." oder ".." sind ohne jeden Schraegstrich schon vollstaendige,
    // gueltige Pfad-Segmente ("ein Verzeichnis hoch") - fuer Dateiname wird
    // das zwar zusaetzlich durch die Endungspruefung in ALLOWED_EXT
    // abgefangen, fuer den Gastnamen (kein Endungs-Check) explizit blocken.
    if ($s === '' || $s === '.' || $s === '..' || mb_strlen($s) > MAX_NAME_LEN) {
        return '';
    }
    return $s;
}

if (!is_dir(TMP_DIR)) {
    @mkdir(TMP_DIR, 0755, true);
}
if (!is_dir(TMP_DIR) || !is_writable(TMP_DIR)) {
    fail(500, 'Ziel-Ordner nicht beschreibbar - Berechtigungen auf der NAS pruefen (siehe README, NAS-Setup).');
}

// Alle Metadaten kommen bewusst aus der Query-String ($_GET), auch beim
// POST: der Request-Body enthaelt ausschliesslich die rohen Chunk-Bytes
// (kein multipart/form-data), sonst muesste PHP den Body erst parsen statt
// ihn direkt per php://input durchzureichen. $_POST bliebe bei einem reinen
// Binary-Body ohnehin leer.
$action = $_GET['action'] ?? '';
$fileId = sanitizeSegment((string)($_GET['fileId'] ?? ''));
if ($fileId === '') fail(400, 'fileId fehlt/ungueltig');

$tmpPath = TMP_DIR . '/' . $fileId . '.part';

// --- Status-Abfrage: wie viele Bytes hat der Server von dieser Datei schon?
//     Fragt upload.js nach einem Seitenneuladen/Tab-Wechsel ab, um genau da
//     weiterzumachen statt die Datei komplett neu zu uebertragen - das ist
//     der eigentliche Kern der "Wiederaufnahme nach Abbruch". ---
if ($action === 'status') {
    $have = is_file($tmpPath) ? filesize($tmpPath) : 0;
    echo json_encode(['bytesReceived' => $have]);
    exit;
}

if ($action !== 'chunk') fail(400, 'Unbekannte action');

$guest = sanitizeSegment((string)($_GET['guest'] ?? ''));
$filename = sanitizeSegment((string)($_GET['filename'] ?? ''));
$chunkIndex = (int)($_GET['chunkIndex'] ?? -1);
$totalSize = (int)($_GET['totalSize'] ?? -1);

if ($guest === '' || $filename === '' || $chunkIndex < 0 || $totalSize <= 0) {
    fail(400, 'Pflichtfelder fehlen/ungueltig (guest/filename/chunkIndex/totalSize)');
}

$ext = strtolower(pathinfo($filename, PATHINFO_EXTENSION));
if (!in_array($ext, ALLOWED_EXT, true)) {
    fail(400, 'Dateityp nicht erlaubt: .' . $ext);
}

$chunkData = file_get_contents('php://input');
if ($chunkData === false) fail(400, 'Chunk konnte nicht gelesen werden');
if (strlen($chunkData) > CHUNK_SIZE) fail(400, 'Chunk groesser als erwartet');

// Offset-basiertes Schreiben statt Anhaengen: ein erneut gesendeter Chunk
// (z.B. weil die Antwort auf dem Rueckweg verloren ging, der Chunk selbst
// aber ankam) ueberschreibt einfach denselben Bereich, statt die Datei zu
// verdoppeln - macht Retries von selbst sicher, ohne separate Buchfuehrung
// "welche Chunks sind schon da".
$offset = $chunkIndex * CHUNK_SIZE;
$fh = fopen($tmpPath, 'c+b');
if ($fh === false) fail(500, 'Konnte Zwischendatei nicht oeffnen');
if (!flock($fh, LOCK_EX)) {
    fclose($fh);
    fail(500, 'Konnte Zwischendatei nicht sperren');
}
fseek($fh, $offset);
fwrite($fh, $chunkData);
fflush($fh);
flock($fh, LOCK_UN);
fclose($fh);

$haveNow = filesize($tmpPath);

// --- Alle Bytes da? Fertigstellen. ---
if ($haveNow >= $totalSize) {
    $destDir = TARGET_BASE_DIR . '/' . $guest;
    if (!is_dir($destDir)) {
        @mkdir($destDir, 0755, true);
    }
    if (!is_dir($destDir)) {
        fail(500, 'Gast-Ordner konnte nicht angelegt werden - Berechtigungen pruefen.');
    }

    // realpath()-Check: destDir muss tatsaechlich unterhalb von
    // TARGET_BASE_DIR liegen, selbst nach sanitizeSegment() zusaetzliche
    // Absicherung falls sich die Sanitierung mal aendert.
    $destDirReal = realpath($destDir);
    $baseReal = realpath(TARGET_BASE_DIR);
    if ($destDirReal === false || $baseReal === false || !str_starts_with($destDirReal, $baseReal)) {
        fail(500, 'Ungueltiger Zielpfad');
    }

    // Namens-Kollision (z.B. zwei "IMG_0001.jpg" vom selben Gast, oder ein
    // Gast laedt dieselbe Datei zweimal hoch) nicht stillschweigend
    // ueberschreiben, sondern durchnummerieren.
    $destPath = $destDir . '/' . $filename;
    if (is_file($destPath)) {
        $pi = pathinfo($filename);
        $base = $pi['filename'];
        $extSuffix = isset($pi['extension']) ? '.' . $pi['extension'] : '';
        $n = 2;
        do {
            $destPath = $destDir . '/' . $base . '_' . $n . $extSuffix;
            $n++;
        } while (is_file($destPath));
    }

    if (!rename($tmpPath, $destPath)) {
        fail(500, 'Datei konnte nicht fertiggestellt werden');
    }

    echo json_encode(['done' => true, 'bytesReceived' => $haveNow]);
    exit;
}

echo json_encode(['done' => false, 'bytesReceived' => $haveNow]);
