<?php
declare(strict_types=1);

// resolve-guest.php — loest den vom Gast eingegebenen Code (z. B. "kx9m3p")
// auf den internen Personen-Slug (z. B. "julia") auf. Genutzt von photos.php
// und image.php, damit Gaeste einen kurzen, nicht erratbaren Code eingeben
// statt einen personalisierten Link mit ihrem Namen zu bekommen.
//
// Bewusst KEIN Fallback auf den Rohwert als Slug: ein Code, der nicht in
// codes.json steht, gilt als ungueltig. Sonst waere das ganze Code-System
// durch simples Erraten eines Namens (z.B. "julia" statt eines Codes)
// umgehbar und die Zugriffskontrolle wirkungslos.

const CODES_FILE = '/volume1/homes/Nicolai/Photos/Moments/Selina/20260912_Hochzeit_Traumfrau/gallery-data/codes.json';

function resolve_guest_code(string $code): ?string {
    if (!is_file(CODES_FILE)) return null;
    $codes = json_decode((string)file_get_contents(CODES_FILE), true);
    if (!is_array($codes) || !isset($codes[$code]) || !is_string($codes[$code])) return null;
    return $codes[$code];
}
