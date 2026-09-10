<?php
// sync-clean.php - findet Fast-Duplikate direkt in GuestPhotos auf der NAS
// (dasselbe Foto mehrfach hochgeladen, nur ein kleiner Metadaten-Unterschied
// am Dateiende - typisch bei Google Fotos/Pixel Motion Photos/Samsung
// Burst-Cover beim wiederholten Teilen/Exportieren) und verschiebt
// Ueberzaehlige nach @Duplikate_Entfernt (NICHT geloescht, jederzeit durch
// Zurueckverschieben rueckgaengig zu machen). list.php ignoriert @-Ordner
// bereits (wie Synologys eigener @eaDir) - dadurch sieht die Diashow
// automatisch eine bereinigte Ansicht, ohne dass list.php selbst etwas
// pruefen muss.
//
// Gleiche Erkennung wie run-local.ps1 (SHA-256 ueber den Dateiinhalt ohne
// die letzten 8 KB) und cleanup-nas-duplicates.ps1 - hier als PHP, weil auf
// dieser NAS kein PowerShell verfuegbar ist. Per DSM Aufgabenplanung alle
// 5 Minuten laufen lassen, damit auch waehrend der Feier neu hochgeladene
// Duplikate zeitnah rausgefiltert werden, ohne bei jedem Lauf den ganzen
// Ordner neu zu hashen (Manifest merkt sich Groesse+Aenderungsdatum bereits
// geprüfter Dateien).
//
// WICHTIG: noch nicht auf der echten NAS getestet (SSH war beim Schreiben
// deaktiviert) - vor dem Scharfschalten der 5-Minuten-Aufgabe einmal manuell
// ueber die DSM-Aufgabenplanung ("Ausfuehren") anstossen und die Ausgabe
// pruefen.

$baseDir = __DIR__ . '/GuestPhotos';
$trashDir = $baseDir . '/@Duplikate_Entfernt';
$manifestPath = __DIR__ . '/.sync-clean-manifest.json';
$allowedExt = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'heic', 'heif'];
$tailMargin = 8192;
$minAgeSeconds = 30; // Schutz gegen einen noch nicht fertig hochgeladenen Gast-Upload

function bodyHash(string $path, int $tailMargin): ?string {
    $size = filesize($path);
    if ($size === false) return null;
    $len = $size > $tailMargin ? $size - $tailMargin : $size;
    $fh = fopen($path, 'rb');
    if (!$fh) return null;
    $ctx = hash_init('sha256');
    $remaining = $len;
    while ($remaining > 0) {
        $chunk = fread($fh, min(1048576, $remaining));
        if ($chunk === false || $chunk === '') break;
        hash_update($ctx, $chunk);
        $remaining -= strlen($chunk);
    }
    fclose($fh);
    return hash_final($ctx);
}

$manifest = [];
if (file_exists($manifestPath)) {
    $decoded = json_decode((string)file_get_contents($manifestPath), true);
    if (is_array($decoded)) $manifest = $decoded;
}

$knownHashes = [];
foreach ($manifest as $entry) {
    if (!empty($entry['kept']) && !empty($entry['hash'])) {
        $knownHashes[$entry['hash']] = true;
    }
}

if (!is_dir($baseDir)) {
    echo date('Y-m-d H:i:s') . "  GuestPhotos nicht gefunden: $baseDir\n";
    exit(1);
}

// Gleiches Filtermuster wie list.php: @-Ordner (Synologys @eaDir und unser
// eigener @Duplikate_Entfernt) ueberspringen, sonst wird schon Verschobenes
// erneut angefasst bzw. Thumbnails als Fotos mitgezaehlt.
$filtered = new RecursiveCallbackFilterIterator(
    new RecursiveDirectoryIterator($baseDir, FilesystemIterator::SKIP_DOTS),
    fn($current) => !($current->isDir() && str_starts_with($current->getFilename(), '@'))
);
$iterator = new RecursiveIteratorIterator($filtered);

$checked = 0;
$unchanged = 0;
$moved = 0;
$now = time();

foreach ($iterator as $file) {
    if (!$file->isFile()) continue;

    $ext = strtolower(pathinfo($file->getFilename(), PATHINFO_EXTENSION));
    if (!in_array($ext, $allowedExt, true)) continue;

    $relative = substr($file->getPathname(), strlen($baseDir) + 1);
    if (!mb_check_encoding($relative, 'UTF-8')) continue;

    $mtime = $file->getMTime();
    $size = $file->getSize();

    if (($now - $mtime) < $minAgeSeconds) continue;

    if (isset($manifest[$relative]) && $manifest[$relative]['size'] === $size && $manifest[$relative]['mtime'] === $mtime) {
        $unchanged++;
        continue;
    }

    $checked++;
    $hash = bodyHash($file->getPathname(), $tailMargin);
    if ($hash === null) continue;

    if (isset($knownHashes[$hash])) {
        $destPath = $trashDir . '/' . $relative;
        $destDir = dirname($destPath);
        if (!is_dir($destDir)) mkdir($destDir, 0755, true);
        if (@rename($file->getPathname(), $destPath)) {
            $manifest[$relative] = ['size' => $size, 'mtime' => $mtime, 'hash' => $hash, 'kept' => false];
            $moved++;
        }
    } else {
        $knownHashes[$hash] = true;
        $manifest[$relative] = ['size' => $size, 'mtime' => $mtime, 'hash' => $hash, 'kept' => true];
    }
}

file_put_contents($manifestPath, json_encode($manifest));
echo date('Y-m-d H:i:s') . "  $checked neu/geaendert geprueft, $unchanged unveraendert uebersprungen, $moved Duplikate verschoben\n";
