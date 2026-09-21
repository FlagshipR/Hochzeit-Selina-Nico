<?php
declare(strict_types=1);

// photos.php — liefert die Foto-Liste eines Gastes als JSON, auf Basis der
// Personen-Zuordnung aus der Gesichtserkennung (siehe gallery-data/
// person-photos.json, von einem separaten Claude-Skript erzeugt, nicht Teil
// dieser Codebasis). Liefert nur Metadaten (Dateiname, Typ, Index) - den
// vollen NAS-Pfad bekommt der Client nie zu sehen, der bleibt ausschliesslich
// serverseitig in image.php.

const DATA_FILE = '/volume1/homes/Nicolai/Photos/Moments/Selina/20260912_Hochzeit_Traumfrau/gallery-data/person-photos.json';

header('Content-Type: application/json; charset=utf-8');

function fail(int $code, string $msg): void {
    http_response_code($code);
    echo json_encode(['error' => $msg]);
    exit;
}

$guest = strtolower((string)($_GET['g'] ?? ''));
// Nur a-z/0-9/Bindestrich - passend zur Code-/Slug-Erzeugung im
// Datengenerator, verhindert jede Form von Injection ueber den Parameter
// von vornherein.
if (!preg_match('/^[a-z0-9-]{1,60}$/', $guest)) {
    fail(400, 'Ungueltiger Code');
}

require __DIR__ . '/resolve-guest.php';
$slug = resolve_guest_code($guest);
if ($slug === null) {
    fail(404, 'Diesen Code kennen wir leider nicht');
}

if (!is_file(DATA_FILE)) {
    fail(500, 'Personendaten nicht gefunden - wurde gallery-data/person-photos.json deployed?');
}
$data = json_decode((string)file_get_contents(DATA_FILE), true);
if (!is_array($data)) {
    // Eigene Fehlermeldung statt in "Gast nicht gefunden" mitzurutschen -
    // sonst sieht ein kaputter Dateianfang (z.B. ein von PowerShell
    // hinzugefuegtes UTF-8-BOM, das json_decode() nicht akzeptiert) genauso
    // aus wie ein einfacher Tippfehler im Link.
    fail(500, 'Personendaten konnten nicht gelesen werden (' . json_last_error_msg() . ')');
}
if (!isset($data[$slug])) {
    fail(404, 'Diesen Code kennen wir leider nicht');
}

$entry = $data[$slug];
$photos = [];
foreach ($entry['photos'] as $i => $p) {
    $photos[] = ['i' => $i, 'filename' => $p['filename'], 'type' => $p['type']];
}

echo json_encode(['name' => $entry['name'], 'photos' => $photos]);
