<?php
// list.php — liefert alle Bilddateien aus GuestPhotos (inkl. aller Unterordner) als JSON.
// Muss im selben Verzeichnis wie der Ordner "GuestPhotos" liegen (Web-Station-Dokumentenstamm
// = /volume1/Hochzeitsfotos), damit die zurückgegebenen Pfade direkt als statische
// Bild-URLs funktionieren.
//
// Liefert bevorzugt aus Vorbereitet/ (von run-local.ps1 auf dem Laptop
// erzeugt: HEIC->JPEG dekodiert, auf Beamer-Aufloesung herunterskaliert) -
// Dateiname dort ist immer "<Originalname>.jpg", z.B.
// "GuestPhotos/Julia/IMG_0927.HEIC" -> "Vorbereitet/Julia/IMG_0927.HEIC.jpg".
// Faellt auf das Original zurueck, falls der Laptop es noch nicht
// verarbeitet hat (z.B. gerade erst hochgeladen, oder Laptop war laengere
// Zeit aus) - damit blockiert nichts die Anzeige, auch wenn der Laptop mal
// nicht mitlaeuft.

header('Content-Type: application/json; charset=utf-8');

$baseDir = __DIR__ . '/GuestPhotos';
$preparedDir = __DIR__ . '/Vorbereitet';
// heic/heif: falls (noch) keine vorbereitete Version existiert, dekodiert
// slideshow.html das HEIC-Original client-seitig als Fallback (siehe dort).
$allowedExt = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'heic', 'heif'];

$images = [];

if (is_dir($baseDir)) {
    // Synology legt in jedem Ordner automatisch ein verstecktes @eaDir mit
    // selbst generierten Thumbnails an (z.B. sobald der Ordner in File Station
    // geoeffnet wurde). SKIP_DOTS ueberspringt nur "." und "..", nicht @eaDir -
    // ohne diesen Filter taucht jedes Foto zusaetzlich als niedrig aufgeloestes
    // "Duplikat" auf (mit spaeterem mtime, erscheint also nach dem Original).
    $filtered = new RecursiveCallbackFilterIterator(
        new RecursiveDirectoryIterator($baseDir, FilesystemIterator::SKIP_DOTS),
        fn($current) => !($current->isDir() && str_starts_with($current->getFilename(), '@'))
    );
    $iterator = new RecursiveIteratorIterator($filtered);

    foreach ($iterator as $file) {
        if (!$file->isFile()) continue;

        $ext = strtolower(pathinfo($file->getFilename(), PATHINFO_EXTENSION));
        if (!in_array($ext, $allowedExt, true)) continue;

        $relative = substr($file->getPathname(), strlen($baseDir) + 1);
        if (!mb_check_encoding($relative, 'UTF-8')) continue; // ungewoehnliche Dateinamen ueberspringen statt die ganze Liste zu brechen

        // Vorbereitete (HEIC->JPEG dekodierte, skalierte) Version bevorzugen,
        // falls der Laptop dieses Foto schon verarbeitet hat.
        $preparedPath = $preparedDir . '/' . $relative . '.jpg';
        if (is_file($preparedPath)) {
            $fullRelativePath = 'Vorbereitet/' . $relative . '.jpg';
            $mtime = filemtime($preparedPath);
        } else {
            $fullRelativePath = 'GuestPhotos/' . $relative;
            $mtime = $file->getMTime();
        }

        // Der erste Pfadteil ist der von Synology automatisch angelegte
        // Unterordner pro Gast (Name aus der Dateianforderung) - das nutzen
        // wir als User-Kennung fuer die Round-Robin-Reihenfolge in der Slideshow.
        $parts = explode('/', $relative);
        $user  = count($parts) > 1 ? $parts[0] : '_unbekannt';

        $images[] = [
            'url'   => encode_path($fullRelativePath),
            'user'  => $user,
            'mtime' => $mtime,
        ];
    }
}

usort($images, fn($a, $b) => $a['mtime'] <=> $b['mtime']);

$json = json_encode(array_values($images));
echo $json !== false ? $json : '[]';

function encode_path(string $path): string {
    return implode('/', array_map('rawurlencode', explode('/', $path)));
}
