<#
.SYNOPSIS
  Findet Fast-Duplikate direkt in GuestPhotos auf der NAS - dasselbe Foto/
  Video mehrfach hochgeladen mit nur einem winzigen Metadaten-Unterschied am
  Dateiende (z.B. von Google Fotos/Pixel Motion Photos/Samsung Burst-Cover
  beim wiederholten Teilen erzeugt, Bild-/Videoinhalt zu 100% identisch).
  Gleiche Erkennung wie run-local.ps1 (SHA-256 ueber den Dateiinhalt ohne die
  letzten 8 KB).

  Verschiebt ueberzaehlige Kopien NICHT geloescht, sondern in den Unterordner
  "@Duplikate_Entfernt" (Name beginnt mit @, wird von list.php und
  run-local.ps1 automatisch ignoriert - genau wie Synologys eigener
  @eaDir-Ordner). Jederzeit rueckgaengig machbar durch Zurueckverschieben.

  Ohne -MoveToTrash: reiner Trockenlauf, zeigt nur was gefunden wuerde,
  veraendert nichts.

.PARAMETER Source
  GuestPhotos-Ordner auf der NAS.

.PARAMETER MoveToTrash
  Tatsaechlich verschieben statt nur anzuzeigen.

.EXAMPLE
  .\cleanup-nas-duplicates.ps1                  # nur anzeigen (sicher)
  .\cleanup-nas-duplicates.ps1 -MoveToTrash     # tatsaechlich verschieben
#>
param(
    [string]$Source = "\\FLANAS\Hochzeitsfotos\GuestPhotos",
    [switch]$MoveToTrash
)

$ErrorActionPreference = 'Stop'
$allowedExt = @('.jpg', '.jpeg', '.png', '.webp', '.gif', '.heic', '.heif')
$trashRoot = Join-Path $Source '@Duplikate_Entfernt'
$margin = 8192

$files = Get-ChildItem -LiteralPath $Source -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $allowedExt -contains $_.Extension.ToLower() -and $_.FullName -notmatch '\\@' }
"Gescannte Dateien: $($files.Count)"

$sha = [System.Security.Cryptography.SHA256]::Create()
$bySize = $files | Group-Object Length | Where-Object { $_.Count -gt 1 }

$toRemove = @()
foreach ($grp in $bySize) {
    $withHash = $grp.Group | ForEach-Object {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        $bodyLen = if ($bytes.Length -gt $margin) { $bytes.Length - $margin } else { $bytes.Length }
        $h = [BitConverter]::ToString($sha.ComputeHash($bytes, 0, $bodyLen)) -replace '-', ''
        [PSCustomObject]@{ File = $_; Hash = $h }
    }
    $hashGroups = $withHash | Group-Object Hash | Where-Object { $_.Count -gt 1 }
    foreach ($hg in $hashGroups) {
        # Kuerzester Dateiname (= ohne _1/_2-Suffix) bleibt, der Rest ist ueberzaehlig.
        $sorted = $hg.Group | Sort-Object { $_.File.Name.Length }
        $keep = $sorted[0]
        $redundant = $sorted[1..($sorted.Count - 1)]
        "[$($hg.Count)x, $($grp.Name) Bytes] behalten: $($keep.File.FullName)"
        foreach ($r in $redundant) {
            "   -> ueberzaehlig: $($r.File.FullName)"
            $toRemove += $r.File
        }
    }
}
$sha.Dispose()

""
"Insgesamt ueberzaehlig: $($toRemove.Count) von $($files.Count) Dateien"

if (-not $MoveToTrash) {
    ""
    "Trockenlauf - nichts veraendert. Mit -MoveToTrash tatsaechlich nach '$trashRoot' verschieben."
    return
}

New-Item -ItemType Directory -Path $trashRoot -Force | Out-Null
foreach ($f in $toRemove) {
    $rel = $f.FullName.Substring($Source.Length).TrimStart('\')
    $dest = Join-Path $trashRoot $rel
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Move-Item -LiteralPath $f.FullName -Destination $dest -Force
}
"$($toRemove.Count) Dateien nach '$trashRoot' verschoben (nicht geloescht, jederzeit rueckgaengig)."
