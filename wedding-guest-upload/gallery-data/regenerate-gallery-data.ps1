# regenerate-gallery-data.ps1 — baut person-photos.json UND codes.json (die
# Dateien, die photos.php/image.php tatsaechlich lesen) aus den Listen unter
# lists/*.txt UND den Gruppen unter groups/*.txt.
#
# Die Listen sind die Quelle der Wahrheit und zum Handbearbeiten gedacht:
# eine Zeile = ein voller NAS-Pfad. Zeile loeschen = Foto raus, Zeile
# hinzufuegen = Foto rein, neue Datei (z. B. "Angelina.txt") = neue Person.
# Dateiname wird 1:1 zum Anzeigenamen (so geschrieben wie benannt, z. B.
# "Nadja Czerny.txt" -> "Nadja Czerny") und intern zum URL-Slug vereinfacht
# (klein geschrieben, Leerzeichen/Umlaute zu Bindestrichen/ae-oe-ue).
# Abweichenden Anzeigenamen erzwingen: Zeile "# Name: <Name>".
#
# groups/<Gruppenname>.txt funktioniert genauso, nur dass jede Zeile ein
# PERSONENNAME ist (muss zu einer Datei in lists/ passen), keine Pfadzeile.
# Die Gruppe zeigt die VEREINIGUNGSMENGE der Fotos aller aufgelisteten
# Personen (dedupliziert). Ein Name, der zu keiner Datei in lists/ passt,
# wird stillschweigend uebersprungen (traegt einfach noch nichts zur
# Vereinigungsmenge bei) - kein Fehler, praktisch fuer Leute, die schon in
# einer Gruppe stehen sollen, aber noch keine zugeordneten Fotos haben.
#
# Zugriff fuer Gaeste laeuft NICHT ueber den Slug/Namen, sondern ueber einen
# kurzen zufaelligen Code (galerie.html fragt danach) - ein Name waere leicht
# zu erraten, ein Zufallscode nicht. Sowohl Personen als auch Gruppen
# bekommen je einen eigenen Code. Der Code wird beim ersten Lauf erzeugt und
# als "# Code: <code>" in die jeweilige lists/*.txt bzw. groups/*.txt
# zurueckgeschrieben, damit er bei jedem weiteren Lauf STABIL bleibt (ein
# einmal verteilter Code darf sich nie mehr aendern). Manuell ueberschreibbar,
# genau wie "# Name:" - z.B. fuer einen persoenlichen Code statt Zufallsstring.
#
# Aufruf (cmd oder PowerShell): powershell -File regenerate-gallery-data.ps1
# Danach person-photos.json UND codes.json auf die NAS deployen (siehe
# README, Abschnitt "Personen-Galerie"). Die am Ende ausgegebene
# Name/Code-Tabelle ist die Liste, die tatsaechlich an die Gaeste verteilt
# wird (Code, nicht der Link).

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$listsDir = Join-Path $here 'lists'
$groupsDir = Join-Path $here 'groups'
$outFile = Join-Path $here 'person-photos.json'
$codesFile = Join-Path $here 'codes.json'

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

# Ohne 0/1/i/l/o (zu leicht verwechselbar, v.a. handschriftlich/vorgelesen).
$codeAlphabet = 'abcdefghjkmnpqrstuvwxyz23456789'
$codeRng = [System.Random]::new()
$codeLength = 10
function New-GuestCode($existingCodes) {
    do {
        $code = -join (1..$codeLength | ForEach-Object { $codeAlphabet[$codeRng.Next($codeAlphabet.Length)] })
    } while ($existingCodes.Contains($code))
    return $code
}

# Gemeinsame Code-Logik fuer Personen- UND Gruppen-Dateien: vorhandenen
# Code aus den geparsten Zeilen wiederverwenden, sonst neu erzeugen. Gibt
# zurueck, ob ein neuer Code erzeugt wurde (dann muss die Quelldatei
# aktualisiert werden, sonst nicht).
function Resolve-GuestCode([string]$existingCode, [System.Collections.Generic.HashSet[string]]$usedCodes) {
    if ($existingCode) {
        $usedCodes.Add($existingCode) | Out-Null
        return [PSCustomObject]@{ Code = $existingCode; IsNew = $false }
    }
    $code = New-GuestCode $usedCodes
    $usedCodes.Add($code) | Out-Null
    return [PSCustomObject]@{ Code = $code; IsNew = $true }
}

$out = [ordered]@{}
$codesOut = [ordered]@{}
$usedCodes = New-Object System.Collections.Generic.HashSet[string]
$summary = @()
$listFiles = Get-ChildItem -Path $listsDir -Filter '*.txt' | Sort-Object Name

foreach ($file in $listFiles) {
    $displayName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $slug = Get-Slug $displayName
    $rawLines = Get-Content -Path $file.FullName -Encoding UTF8 | Where-Object { $_.Trim() -ne '' }

    $code = $null
    $otherLines = @()  # alles ausser "# Code:" - Reihenfolge bleibt erhalten
    foreach ($line in $rawLines) {
        if ($line.StartsWith('# Name:')) {
            $displayName = $line.Substring(7).Trim()
            $otherLines += $line
            continue
        }
        if ($line.StartsWith('# Code:')) {
            $code = $line.Substring(7).Trim().ToLower()
            continue
        }
        $otherLines += $line
    }

    $resolved = Resolve-GuestCode $code $usedCodes
    $code = $resolved.Code
    $codeIsNew = $resolved.IsNew
    $codesOut[$code] = $slug

    if ($codeIsNew) {
        # Neuen Code dauerhaft ganz oben in die Liste zurueckschreiben -
        # bleibt so beim naechsten Lauf stabil statt bei jedem Aufruf neu
        # erzeugt zu werden. Reihenfolge der uebrigen Zeilen (inkl. "# Name:")
        # bleibt unveraendert, die Position von "# Code:" ist PHP/dem Parser
        # oben egal.
        $newLines = @("# Code: $code") + $otherLines
        Set-Content -Path $file.FullName -Value $newLines -Encoding UTF8
    }

    $photoLines = $otherLines | Where-Object { -not $_.StartsWith('#') } | ForEach-Object { $_.Trim() }

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
    $summary += [PSCustomObject]@{ Name = $displayName; Code = $code; Fotos = $photos.Count; Neu = $codeIsNew }
}

$groupSummary = @()
if (Test-Path $groupsDir) {
    $groupFiles = Get-ChildItem -Path $groupsDir -Filter '*.txt' | Sort-Object Name
    foreach ($file in $groupFiles) {
        $groupDisplayName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $groupSlug = Get-Slug $groupDisplayName
        $rawLines = Get-Content -Path $file.FullName -Encoding UTF8 | Where-Object { $_.Trim() -ne '' }

        $code = $null
        $memberNames = @()
        foreach ($line in $rawLines) {
            if ($line.StartsWith('# Name:')) { $groupDisplayName = $line.Substring(7).Trim(); continue }
            if ($line.StartsWith('# Code:')) { $code = $line.Substring(7).Trim().ToLower(); continue }
            if ($line.StartsWith('#')) { continue }
            $memberNames += $line.Trim()
        }

        # Vereinigungsmenge der Fotos aller Mitglieder, dedupliziert nach
        # Pfad (derselbe Pfad kann bei mehreren Mitgliedern auftauchen, wenn
        # sie gemeinsam auf einem Foto zu sehen sind).
        $seenPaths = New-Object System.Collections.Generic.HashSet[string]
        $unionPhotos = @()
        $missingMembers = @()
        foreach ($memberName in $memberNames) {
            $memberSlug = Get-Slug $memberName
            if (-not $out.Contains($memberSlug)) { $missingMembers += $memberName; continue }
            foreach ($p in $out[$memberSlug].photos) {
                if ($seenPaths.Add($p.path)) { $unionPhotos += $p }
            }
        }

        $resolved = Resolve-GuestCode $code $usedCodes
        $code = $resolved.Code
        $codeIsNew = $resolved.IsNew
        $codesOut[$code] = $groupSlug

        if ($codeIsNew) {
            $newLines = @("# Code: $code") + ($rawLines | Where-Object { -not $_.StartsWith('# Code:') })
            Set-Content -Path $file.FullName -Value $newLines -Encoding UTF8
        }

        $out[$groupSlug] = [ordered]@{ name = $groupDisplayName; photos = $unionPhotos }
        $groupSummary += [PSCustomObject]@{
            Gruppe = $groupDisplayName; Code = $code; Fotos = $unionPhotos.Count
            Mitglieder = $memberNames.Count; OhneFotos = ($missingMembers -join ', ')
        }
    }
}

# Set-Content -Encoding UTF8 schreibt in Windows PowerShell 5.1 immer ein BOM
# (Byte-Order-Mark) an den Dateianfang - PHPs json_decode() akzeptiert das
# nicht und scheitert mit einem Syntax-Fehler, den man leicht fuer "Gast
# nicht gefunden" haelt statt fuer einen kaputten Dateianfang. Deshalb hier
# bewusst .NET direkt statt Set-Content, mit explizit BOM-loser Kodierung.
$json = $out | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($outFile, $json, (New-Object System.Text.UTF8Encoding $false))
$codesJson = $codesOut | ConvertTo-Json -Depth 2
[System.IO.File]::WriteAllText($codesFile, $codesJson, (New-Object System.Text.UTF8Encoding $false))

Write-Output "person-photos.json geschrieben: $outFile"
Write-Output "codes.json geschrieben: $codesFile"
Write-Output ""
Write-Output "=== Personen-Codes (intern/Admin, z.B. fuer die Uebersichtsseite) ==="
$summary | Sort-Object Name | Format-Table Name, Code, Fotos, Neu -AutoSize | Out-String -Width 200

if ($groupSummary.Count -gt 0) {
    Write-Output "=== Gruppen-Codes zum Verteilen (ein Code pro Gruppen-Chat) ==="
    $groupSummary | Format-Table Gruppe, Code, Fotos, Mitglieder, OhneFotos -AutoSize | Out-String -Width 200
    $leer = $groupSummary | Where-Object { $_.Fotos -eq 0 }
    if ($leer) {
        Write-Output "Noch ohne Fotos (Code existiert, Galerie waere aktuell leer): $($leer.Gruppe -join ', ')"
    }
}
