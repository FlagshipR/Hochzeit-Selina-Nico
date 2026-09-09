<#
.SYNOPSIS
  Synchronisiert Gaestefotos von der NAS auf die lokale Platte (mit Dedup per
  Inhalts-Hash) und stellt sie zusammen mit slideshow.html ueber einen
  lokalen Webserver bereit - damit die Diashow waehrend der Feier komplett
  ohne Live-Netzwerkzugriff laeuft, selbst wenn VPN/Verbindung zur NAS
  zwischendurch abbricht. Braucht nur Windows PowerShell, keine Zusatz-
  Installation.

.PARAMETER Source
  UNC-Pfad zum GuestPhotos-Ordner auf der NAS (Netzwerk oder VPN erreichbar).

.PARAMETER CacheRoot
  Lokaler Ordner fuer die heruntergeladenen Fotos + list.json. Bewusst
  ausserhalb des Git-Repos (Standard: Downloads-Ordner) - so koennen die
  echten Gaestefotos nie versehentlich in dieses oeffentliche Repo geraten.

.PARAMETER IntervalSeconds
  Wie oft neu synchronisiert wird (Default 12 Minuten - unveraenderte Dateien
  werden anhand von Groesse+Aenderungsdatum erkannt und uebersprungen, ohne
  erneut gehasht/kopiert zu werden, ein kuerzeres Intervall kostet also vor
  allem zusaetzliche Verzeichnis-Abfragen gegen die NAS). Laeuft in einer
  Dauerschleife, die nie von selbst endet - unabhaengig davon, ob seit dem
  letzten Login Minuten oder Tage vergangen sind, nicht nur einmal beim
  Start.

.PARAMETER MinAgeSeconds
  Dateien, die vor kuerzerer Zeit geaendert wurden, werden uebersprungen -
  Schutz gegen einen noch nicht vollstaendig hochgeladenen Gast-Upload.

.PARAMETER Port
  Lokaler Port fuer die Diashow (http://localhost:<Port>/slideshow.html).

.EXAMPLE
  .\run-local.ps1
  .\run-local.ps1 -Source "\\FLANAS\Hochzeitsfotos\GuestPhotos" -Port 8090
#>
param(
    [string]$Source = "\\FLANAS\Hochzeitsfotos\GuestPhotos",
    [string]$CacheRoot = (Join-Path $env:USERPROFILE 'Downloads\Hochzeitsfotos-Cache'),
    [int]$IntervalSeconds = 720,
    [int]$MinAgeSeconds = 10,
    [int]$Port = 8090
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$destRoot = $CacheRoot
$listJsonPath = Join-Path $destRoot 'list.json'
$manifestPath = Join-Path $destRoot '.manifest.json'
$allowedExt = @('.jpg', '.jpeg', '.png', '.webp', '.gif', '.heic', '.heif')

if (-not (Test-Path $destRoot)) { New-Item -ItemType Directory -Path $destRoot | Out-Null }

# --- Bestehenden Stand laden, damit ein Neustart des Skripts nicht wieder bei
#     Null anfaengt (nichts wird doppelt kopiert oder erneut gehasht). ---
$knownHashes = New-Object 'System.Collections.Generic.HashSet[string]'
$images = New-Object 'System.Collections.Generic.List[object]'
if (Test-Path $listJsonPath) {
    try {
        $existing = @(Get-Content $listJsonPath -Raw | ConvertFrom-Json)
        foreach ($e in $existing) {
            $images.Add($e)
            if ($e.hash) { [void]$knownHashes.Add($e.hash) }
        }
    } catch {
        Write-Warning "list.json konnte nicht gelesen werden, starte mit leerer Liste: $_"
    }
}

$manifest = @{}
if (Test-Path $manifestPath) {
    try {
        $raw = Get-Content $manifestPath -Raw | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $manifest[$p.Name] = $p.Value }
    } catch {
        Write-Warning "Manifest konnte nicht gelesen werden, starte mit leerem Manifest: $_"
    }
}

function Save-Manifest {
    ($manifest | ConvertTo-Json -Depth 5) | Set-Content -Path $manifestPath -Encoding UTF8
}

function Save-ListJson {
    # $images.Count vorab pruefen statt dem Pipeline-Ergebnis zu vertrauen:
    # "@($x | Sort-Object ...)" bei leerem $x ergibt in PowerShell ein
    # 1-Element-Array mit $null drin (nicht ein leeres Array) - wuerde sonst
    # als "[null]" statt "[]" geschrieben und die Slideshow-Seite crashen.
    if ($images.Count -eq 0) {
        $json = '[]'
    } else {
        $sorted = @($images | Sort-Object mtime)
        $json = ConvertTo-Json -InputObject $sorted -Depth 5
    }
    $tmp = "$listJsonPath.tmp"
    Set-Content -Path $tmp -Value $json -Encoding UTF8
    Move-Item -Path $tmp -Destination $listJsonPath -Force
}

function Sync-Once {
    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Warning "$(Get-Date -Format 'HH:mm:ss')  Quelle nicht erreichbar: $Source (naechster Versuch in $IntervalSeconds s)"
        return
    }

    try {
        $files = Get-ChildItem -LiteralPath $Source -Recurse -File -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "$(Get-Date -Format 'HH:mm:ss')  Fehler beim Auflisten von $Source : $_"
        return
    }

    $newCount = 0
    $dupCount = 0
    $changed = $false

    foreach ($f in $files) {
        $ext = $f.Extension.ToLowerInvariant()
        if ($allowedExt -notcontains $ext) { continue }

        $relSource = $f.FullName.Substring($Source.Length).TrimStart('\')
        $segments = $relSource -split '\\'

        # Synologys automatisch angelegter @eaDir-Thumbnail-Ordner (in jedem
        # Verzeichnis, sobald es mal in File Station geoeffnet wurde) muss
        # raus, sonst taucht jedes Foto zusaetzlich als Duplikat auf.
        $inEaDir = $false
        for ($k = 0; $k -lt $segments.Length - 1; $k++) {
            if ($segments[$k].StartsWith('@')) { $inEaDir = $true; break }
        }
        if ($inEaDir) { continue }

        $user = if ($segments.Length -gt 1) { $segments[0] } else { '_unbekannt' }

        $age = (Get-Date) - $f.LastWriteTime
        if ($age.TotalSeconds -lt $MinAgeSeconds) { continue }  # evtl. noch mitten im Upload

        $manifestKey = $relSource
        $mtimeTicks = $f.LastWriteTimeUtc.Ticks
        if ($manifest.ContainsKey($manifestKey)) {
            $known = $manifest[$manifestKey]
            if ($known.size -eq $f.Length -and $known.mtime -eq $mtimeTicks) {
                continue  # unveraendert seit letztem Lauf, schon behandelt (kopiert oder Duplikat)
            }
        }

        try {
            $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        } catch {
            Write-Warning "$(Get-Date -Format 'HH:mm:ss')  Hash fehlgeschlagen fuer $relSource - ueberspringe: $_"
            continue
        }

        if ($knownHashes.Contains($hash)) {
            $manifest[$manifestKey] = @{ size = $f.Length; mtime = $mtimeTicks; status = 'duplicate' }
            $dupCount++
            $changed = $true
            continue
        }

        $destUserDir = Join-Path $destRoot $user
        if (-not (Test-Path $destUserDir)) { New-Item -ItemType Directory -Path $destUserDir | Out-Null }

        $destName = $f.Name
        $destPath = Join-Path $destUserDir $destName
        $suffix = 1
        while (Test-Path -LiteralPath $destPath) {
            $destName = "{0}_{1}{2}" -f $f.BaseName, $suffix, $f.Extension
            $destPath = Join-Path $destUserDir $destName
            $suffix++
        }

        Copy-Item -LiteralPath $f.FullName -Destination $destPath -Force

        [void]$knownHashes.Add($hash)
        $manifest[$manifestKey] = @{ size = $f.Length; mtime = $mtimeTicks; status = 'copied'; hash = $hash }

        $unixTime = [DateTimeOffset]::new($f.LastWriteTimeUtc).ToUnixTimeSeconds()
        # "cache/" Praefix, weil der lokale Server Code (nas-slideshow/) und
        # Fotos (Downloads/...) aus zwei getrennten Wurzeln bedient.
        $urlPath = ('cache/' + $user + '/' + $destName) -replace ' ', '%20'
        $images.Add([PSCustomObject]@{
            url   = $urlPath
            user  = $user
            mtime = $unixTime
            hash  = $hash
        })
        $newCount++
        $changed = $true
    }

    if ($changed) {
        Save-Manifest
        Save-ListJson
        Write-Host "$(Get-Date -Format 'HH:mm:ss')  +$newCount neu, $dupCount Duplikate uebersprungen (insgesamt $($images.Count) Fotos im Cache)"
    }
}

# --- Lokaler statischer Webserver (eigener Hintergrund-Prozess) mit zwei
#     Wurzeln: $root (nas-slideshow/ im Repo - slideshow.html,
#     libheif-bundle.js) fuer alles, und $destRoot (Downloads/... - Bilder +
#     list.json) fuer alles unter "/cache/". Browser blockieren fetch() auf
#     file://, daher noetig - bewusst per HttpListener in reinem PowerShell
#     gebaut statt z.B. python -m http.server, damit auf dem Beamer-Laptop
#     nichts installiert sein muss ausser Windows selbst. ---
$serverJob = Start-Job -Name 'nas-slideshow-server' -ScriptBlock {
    param($root, $cacheRoot, $port)

    $mime = @{
        '.html' = 'text/html; charset=utf-8'
        '.js'   = 'application/javascript'
        '.json' = 'application/json'
        '.jpg'  = 'image/jpeg'
        '.jpeg' = 'image/jpeg'
        '.png'  = 'image/png'
        '.webp' = 'image/webp'
        '.gif'  = 'image/gif'
        '.heic' = 'image/heic'
        '.heif' = 'image/heif'
        '.css'  = 'text/css'
    }

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$port/")

    # Ein vorheriger Lauf (z.B. gerade erst per Stop-ScheduledTask beendet)
    # gibt den Port manchmal nicht sofort frei - ein paar Sekunden Retry statt
    # gleich aufzugeben, das behebt den ueblichen Fall von selbst.
    $started = $false
    for ($attempt = 1; $attempt -le 5 -and -not $started; $attempt++) {
        try {
            $listener.Start()
            $started = $true
        } catch {
            if ($attempt -eq 5) {
                Write-Output "SERVER-FEHLER: konnte Port $port nach $attempt Versuchen nicht oeffnen ($_). Ggf. als Administrator: netsh http add urlacl url=http://localhost:$port/ user=$env:USERNAME"
                return
            }
            Start-Sleep -Seconds 2
        }
    }

    $rootFull = [System.IO.Path]::GetFullPath($root)
    $cacheRootFull = [System.IO.Path]::GetFullPath($cacheRoot)

    while ($listener.IsListening) {
        try {
            $ctx = $listener.GetContext()
        } catch {
            break
        }
        try {
            $reqPath = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath.TrimStart('/'))
            if ([string]::IsNullOrWhiteSpace($reqPath)) { $reqPath = 'slideshow.html' }

            if ($reqPath -eq 'cache' -or $reqPath.StartsWith('cache/')) {
                $relPath = $reqPath.Substring(5).TrimStart('/')
                $baseFull = $cacheRootFull
            } else {
                $relPath = $reqPath
                $baseFull = $rootFull
            }
            $full = [System.IO.Path]::GetFullPath((Join-Path $baseFull $relPath))

            if (-not $full.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
                $ctx.Response.StatusCode = 403
            } elseif (Test-Path -LiteralPath $full -PathType Leaf) {
                $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
                if ($mime.ContainsKey($ext)) {
                    $ctx.Response.ContentType = $mime[$ext]
                } else {
                    $ctx.Response.ContentType = 'application/octet-stream'
                }
                $bytes = [System.IO.File]::ReadAllBytes($full)
                $ctx.Response.ContentLength64 = $bytes.Length
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            } else {
                $ctx.Response.StatusCode = 404
            }
        } catch {
        } finally {
            $ctx.Response.OutputStream.Close()
        }
    }
} -ArgumentList $root, $destRoot, $Port

Start-Sleep -Milliseconds 700
$jobOutput = Receive-Job -Job $serverJob -ErrorAction SilentlyContinue
if ($jobOutput) { Write-Warning $jobOutput }

Write-Host "======================================================"
Write-Host " Diashow lokal: http://localhost:$Port/slideshow.html"
Write-Host " Quelle:        $Source"
Write-Host " Lokaler Cache: $destRoot"
Write-Host " Strg+C zum Beenden (stoppt auch den lokalen Server)"
Write-Host "======================================================"

try {
    while ($true) {
        Sync-Once
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    Write-Host "Beende lokalen Server..."
    Stop-Job -Job $serverJob -ErrorAction SilentlyContinue | Out-Null
    Remove-Job -Job $serverJob -Force -ErrorAction SilentlyContinue | Out-Null
}
