<?php
declare(strict_types=1);

// uebersicht.php — passwortgeschuetzte Admin-Uebersicht (Personen/Gruppen
// + ihre Codes). Bewusst NICHT unter demselben zufaelligen Pfad wie die
// Gast-Seiten (galerie.html usw.) deployed, sondern unter einem eigenen,
// separaten Zufalls-Pfad: diese Seite zeigt jeden vergebenen Code im
// Klartext, darf also nie ueber den an Gaeste verteilten Link
// erreichbar/erratbar sein.

// Passwort-Hash, NICHT das Klartext-Passwort - mit password_hash() erzeugt.
// Neues Passwort setzen: php -r "echo password_hash('neues-passwort', PASSWORD_DEFAULT);"
// und den Hash hier ersetzen.
const PASSWORD_HASH = '$2y$10$PLACEHOLDER.PLACEHOLDER.PLACEHOLDER.PLACEHOLDERxx';

const CONTENT_FILE = '/volume1/homes/Nicolai/Photos/Moments/Selina/20260912_Hochzeit_Traumfrau/gallery-data/uebersicht-content.html';

session_set_cookie_params([
    'lifetime' => 60 * 60 * 24 * 30, // 30 Tage - eigenes Admin-Tool, kein haeufiges Neu-Einloggen noetig
    'path' => '/',
    'secure' => true,
    'httponly' => true,
    'samesite' => 'Lax',
]);
session_start();

$error = null;
if (isset($_POST['password'])) {
    if (password_verify((string)$_POST['password'], PASSWORD_HASH)) {
        session_regenerate_id(true);
        $_SESSION['uebersicht_auth'] = true;
    } else {
        $error = 'Falsches Passwort';
    }
}

if (empty($_SESSION['uebersicht_auth'])) {
    header('Content-Type: text/html; charset=utf-8');
    ?>
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="robots" content="noindex, nofollow">
<title>Übersicht – Login</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #faf7f2; color: #2b2622; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
  form { background: #fffdfa; border: 1px solid #e7ddd1; border-radius: 16px; padding: 32px; text-align: center; }
  input[type=password] { padding: 10px 14px; border: 1px solid #e7ddd1; border-radius: 10px; font-size: 1rem; margin-bottom: 12px; width: 200px; display: block; }
  button { background: #a9765a; color: #fff; border: none; border-radius: 999px; padding: 10px 24px; font-size: 0.95rem; cursor: pointer; width: 100%; }
  button:hover { background: #8a5f47; }
  .error { color: #b3453b; font-size: 0.85rem; margin-bottom: 10px; }
</style>
</head>
<body>
<form method="post">
  <?php if ($error !== null): ?><div class="error"><?= htmlspecialchars($error) ?></div><?php endif; ?>
  <input type="password" name="password" placeholder="Passwort" autofocus autocomplete="current-password">
  <button type="submit">Anmelden</button>
</form>
</body>
</html>
    <?php
    exit;
}

if (!is_file(CONTENT_FILE)) {
    http_response_code(500);
    echo 'Uebersicht nicht gefunden - wurde uebersicht-content.html deployed?';
    exit;
}
header('Content-Type: text/html; charset=utf-8');
readfile(CONTENT_FILE);
