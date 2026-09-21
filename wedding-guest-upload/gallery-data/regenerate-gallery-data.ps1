# regenerate-gallery-data.ps1 — baut person-photos.json (die Datei, die
# photos.php/image.php tatsaechlich lesen) aus den Listen unter lists/*.txt.
#
# Die Listen sind die Quelle der Wahrheit und zum Handbearbeiten gedacht:
# eine Zeile = ein voller NAS-Pfad. Zeile loeschen = Foto raus, Zeile
# hinzufuegen = Foto rein, Datei umbenennen (z. B. angelina.txt) = neue
# Person. Der Dateiname (ohne .txt) wird zum Link-Slug: lists/julia.txt
# -> galerie.html?g=julia. Der Anzeigename kommt aus der ersten Zeile, falls
# sie mit "# Name: " beginnt, sonst aus dem Dateinamen (Grossbuchstabe,
# Bindestriche zu Leerzeichen).
#
# Aufruf (cmd oder PowerShell): powershell -File regenerate-gallery-data.ps1
# Danach person-photos.json auf die NAS deployen (siehe README, Abschnitt
# "Personen-Galerie").

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$listsDir = Join-Path $here 'lists'
$outFile = Join-Path $here 'person-photos.json'

if (-not (Test-Path $listsDir)) {
    Write-Error "Ordner nicht gefunden: $listsDir"
    exit 1
}

function Get-DisplayNameFromSlug($slug) {
    $words = $slug -split '-' | ForEach-Object { if ($_.Length -gt 0) { $_.Substring(0,1).ToUpper() + $_.Substring(1) } }
    return ($words -join ' ')
}

$out = [ordered]@{}
$listFiles = Get-ChildItem -Path $listsDir -Filter '*.txt' | Sort-Object Name

foreach ($file in $listFiles) {
    $slug = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $lines = Get-Content -Path $file.FullName -Encoding UTF8 | Where-Object { $_.Trim() -ne '' }

    $displayName = Get-DisplayNameFromSlug $slug
    $photoLines = @()
    foreach ($line in $lines) {
        if ($line.StartsWith('# Name:')) {
            $displayName = $line.Substring(7).Trim()
            continue
        }
        if ($line.StartsWith('#')) { continue }  # sonstige Kommentarzeilen ueberspringen
        $photoLines += $line.Trim()
    }

    $photos = @()
    foreach ($path in $photoLines) {
        # \\FLANAS\home\... -> /volume1/homes/Nicolai/... (literaler String-Replace,
        # keine Regex - Backslashes sind dabei erfahrungsgemaess eine Minenfeld)
        $posixPath = $path.Replace('\\FLANAS\home\', '/volume1/homes/Nicolai/')
        $posixPath = $posixPath.Replace('\', '/')
        $filename = Split-Path $path -Leaf
        $photos += [ordered]@{ path = $posixPath; filename = $filename; type = 'photo' }
    }

    $out[$slug] = [ordered]@{ name = $displayName; photos = $photos }
}

$json = $out | ConvertTo-Json -Depth 6
Set-Content -Path $outFile -Value $json -Encoding UTF8

Write-Output "person-photos.json geschrieben: $outFile"
foreach ($k in $out.Keys) {
    Write-Output ("  {0,-20} {1,4} Fotos  ->  ?g={2}" -f $out[$k].name, $out[$k].photos.Count, $k)
}
