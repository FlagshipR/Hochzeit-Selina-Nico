<?php
declare(strict_types=1);

// image.php — streamt eine einzelne Datei aus der Personen-Zuordnung direkt
// vom NAS-Pfad an den Browser, ohne sie jemals zu kopieren. Der volle Pfad
// kommt ausschliesslich serverseitig aus person-photos.json - der Client
// kennt nur "Gast + Index" (ein Integer), nie einen Dateinamen oder Pfad.
// Das schliesst Path Traversal von vornherein aus, es gibt keinen
// Client-Input, der je in einen Dateipfad einfliesst.

const DATA_FILE = '/volume1/homes/Nicolai/Photos/Moments/Selina/20260912_Hochzeit_Traumfrau/gallery-data/person-photos.json';

function fail(int $code, string $msg): void {
    http_response_code($code);
    header('Content-Type: text/plain; charset=utf-8');
    echo $msg;
    exit;
}

$guest = (string)($_GET['g'] ?? '');
if (!preg_match('/^[a-z0-9-]{1,60}$/', $guest)) {
    fail(400, 'Ungueltiger Link');
}

$i = filter_input(INPUT_GET, 'i', FILTER_VALIDATE_INT);
if ($i === null || $i === false || $i < 0) {
    fail(400, 'Ungueltiger Index');
}

if (!is_file(DATA_FILE)) {
    fail(500, 'Personendaten nicht gefunden');
}
$data = json_decode((string)file_get_contents(DATA_FILE), true);
if (!is_array($data) || !isset($data[$guest]['photos'][$i])) {
    fail(404, 'Nicht gefunden');
}

$photo = $data[$guest]['photos'][$i];
$path = $photo['path'];

if (!is_file($path)) {
    fail(404, 'Datei nicht mehr vorhanden');
}

$mimeTypes = [
    'jpg' => 'image/jpeg', 'jpeg' => 'image/jpeg', 'png' => 'image/png',
    'heic' => 'image/heic', 'heif' => 'image/heif', 'webp' => 'image/webp', 'gif' => 'image/gif',
    'mp4' => 'video/mp4', 'mov' => 'video/quicktime', 'm4v' => 'video/x-m4v', '3gp' => 'video/3gpp',
];
$ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
$mime = $mimeTypes[$ext] ?? 'application/octet-stream';

$filesize = filesize($path);
if ($filesize === false) fail(500, 'Dateigroesse nicht lesbar');

$isDownload = ($_GET['dl'] ?? '') === '1';

$start = 0;
$end = $filesize - 1;
$isPartial = false;

// HTTP-Range-Unterstuetzung: noetig fuers Video-Scrubbing im Browser und
// fuer zuverlaessige Downloads grosser Dateien auf wackligen mobilen
// Verbindungen (Wiederaufnahme statt Komplettabbruch bei Unterbrechung).
if (isset($_SERVER['HTTP_RANGE']) && preg_match('/bytes=(\d*)-(\d*)/', $_SERVER['HTTP_RANGE'], $m)) {
    if ($m[1] !== '') $start = (int)$m[1];
    if ($m[2] !== '') $end = (int)$m[2];
    $end = min($end, $filesize - 1);
    if ($start <= $end) $isPartial = true;
}

$fh = fopen($path, 'rb');
if ($fh === false) fail(500, 'Datei konnte nicht geoeffnet werden');

header('Content-Type: ' . $mime);
header('Content-Disposition: ' . ($isDownload ? 'attachment' : 'inline') . '; filename="' . rawurlencode($photo['filename']) . '"');
header('Accept-Ranges: bytes');
header('Cache-Control: private, max-age=3600');

if ($isPartial) {
    http_response_code(206);
    header("Content-Range: bytes $start-$end/$filesize");
}
header('Content-Length: ' . ($end - $start + 1));

fseek($fh, $start);
$remaining = $end - $start + 1;
while ($remaining > 0 && !feof($fh)) {
    $chunk = (int)min(1024 * 1024, $remaining);
    echo fread($fh, $chunk);
    $remaining -= $chunk;
    flush();
}
fclose($fh);
