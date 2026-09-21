# regenerate-gallery-data.ps1 — baut person-photos.json (die Datei, die
# photos.php/image.php tatsaechlich lesen) aus den Listen unter lists/*.txt.
#
# Die Listen sind die Quelle der Wahrheit und zum Handbearbeiten gedacht:
# eine Zeile = ein voller NAS-Pfad. Zeile loeschen = Foto raus, Zeile
# hinzufuegen = Foto rein, neue Datei (z. B. "Angelina.txt") = neue Person.
# Dateiname wird 1:1 zum Anzeigenamen (so geschrieben wie benannt, z. B.
# "Nadja Czerny.txt" -> "Nadja Czerny") und automatisch zum URL-Slug
# vereinfacht (klein geschrieben, Leerzeichen/Umlaute zu Bindestrichen/
# ae-oe-ue): "Nadja Czerny.txt" -> galerie.html?g=nadja-czerny. Abweichenden
# Anzeigenamen erzwingen: erste Zeile "# Name: <Name>".
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

function Get-Slug($name) {
    $s = $name.ToLower()
    $s = $s -replace 'ä','ae' -replace 'ö','oe' -replace 'ü','ue' -replace 'ß','ss'
    $s = $s -replace '[^a-z0-9]+','-'
    return $s.Trim('-')
}

$out = [ordered]@{}
$listFiles = Get-ChildItem -Path $listsDir -Filter '*.txt' | Sort-Object Name

foreach ($file in $listFiles) {
    $displayName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $slug = Get-Slug $displayName
    $lines = Get-Content -Path $file.FullName -Encoding UTF8 | Where-Object { $_.Trim() -ne '' }

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
# Set-Content -Encoding UTF8 schreibt in Windows PowerShell 5.1 immer ein BOM
# (Byte-Order-Mark) an den Dateianfang - PHPs json_decode() akzeptiert das
# nicht und scheitert mit einem Syntax-Fehler, den man leicht fuer "Gast
# nicht gefunden" haelt statt fuer einen kaputten Dateianfang. Deshalb hier
# bewusst .NET direkt statt Set-Content, mit explizit BOM-loser Kodierung.
[System.IO.File]::WriteAllText($outFile, $json, (New-Object System.Text.UTF8Encoding $false))

Write-Output "person-photos.json geschrieben: $outFile"
foreach ($k in $out.Keys) {
    Write-Output ("  {0,-20} {1,4} Fotos  ->  ?g={2}" -f $out[$k].name, $out[$k].photos.Count, $k)
}
