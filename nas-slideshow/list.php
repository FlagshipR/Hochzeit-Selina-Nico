<?php
// list.php — liefert alle Bilddateien aus GuestPhotos (inkl. aller Unterordner) als JSON.
// Muss im selben Verzeichnis wie der Ordner "GuestPhotos" liegen (Web-Station-Dokumentenstamm
// = /volume1/Hochzeitsfotos), damit die zurückgegebenen Pfade direkt als statische
// Bild-URLs funktionieren.

header('Content-Type: application/json; charset=utf-8');

$baseDir = __DIR__ . '/GuestPhotos';
$allowedExt = ['jpg', 'jpeg', 'png', 'webp', 'gif'];

$images = [];

if (is_dir($baseDir)) {
    $iterator = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($baseDir, FilesystemIterator::SKIP_DOTS)
    );

    foreach ($iterator as $file) {
        if (!$file->isFile()) continue;

        $ext = strtolower(pathinfo($file->getFilename(), PATHINFO_EXTENSION));
        if (!in_array($ext, $allowedExt, true)) continue;

        $relative = substr($file->getPathname(), strlen($baseDir) + 1);
        $fullRelativePath = 'GuestPhotos/' . $relative;
        if (!mb_check_encoding($fullRelativePath, 'UTF-8')) continue; // ungewoehnliche Dateinamen ueberspringen statt die ganze Liste zu brechen

        // Der erste Pfadteil ist der von Synology automatisch angelegte
        // Unterordner pro Gast (Name aus der Dateianforderung) - das nutzen
        // wir als User-Kennung fuer die Round-Robin-Reihenfolge in der Slideshow.
        $parts = explode('/', $relative);
        $user  = count($parts) > 1 ? $parts[0] : '_unbekannt';

        $images[] = [
            'url'   => encode_path($fullRelativePath),
            'user'  => $user,
            'mtime' => $file->getMTime(),
        ];
    }
}

usort($images, fn($a, $b) => $a['mtime'] <=> $b['mtime']);

$json = json_encode(array_values($images));
echo $json !== false ? $json : '[]';

function encode_path(string $path): string {
    return implode('/', array_map('rawurlencode', explode('/', $path)));
}
