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

.PARAMETER AllowRemote
  Server auch fuer andere Geraete im (V)LAN erreichbar machen statt nur fuer
  diesen Rechner selbst - z.B. damit ein Geraet vor Ort (Fire-TV-Stick per
  WireGuard-VPN ins Heimnetz, oder ein anderes Geraet im selben WLAN) die
  Diashow direkt aufrufen kann, waehrend dieser Rechner zuhause im Heimnetz
  bleibt. Braucht einmalig vorab (als Administrator):
    netsh http add urlacl url=http://+:8090/ user=DOMAIN\Username
    New-NetFirewallRule -DisplayName "Hochzeit-Slideshow" -Direction Inbound -Protocol TCP -LocalPort 8090 -Action Allow
  (Portnummer anpassen falls -Port abweicht). Ohne diese zwei Schritte
  schlaegt das Binden mit -AllowRemote fehl bzw. bleibt von aussen
  unerreichbar, auch wenn der Prozess selbst laeuft.

.EXAMPLE
  .\run-local.ps1
  .\run-local.ps1 -Source "\\FLANAS\Hochzeitsfotos\GuestPhotos" -Port 8090
  .\run-local.ps1 -AllowRemote
#>
param(
    [string]$Source = "\\FLANAS\Hochzeitsfotos\GuestPhotos",
    [string]$CacheRoot = (Join-Path $env:USERPROFILE 'Downloads\Hochzeitsfotos-Cache'),
    [int]$IntervalSeconds = 720,
    [int]$MinAgeSeconds = 10,
    [int]$Port = 8090,
    [switch]$AllowRemote
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$destRoot = $CacheRoot
$listJsonPath = Join-Path $destRoot 'list.json'
$manifestPath = Join-Path $destRoot '.manifest.json'
$allowedExt = @('.jpg', '.jpeg', '.png', '.webp', '.gif', '.heic', '.heif')

if (-not (Test-Path $destRoot)) { New-Item -ItemType Directory -Path $destRoot | Out-Null }

# --- Nur eine Instanz gleichzeitig: live beobachtet, dass z.B. ein Sleep/
#     Wake-Zyklus oder ein manueller Zusatzstart eine zweite Instanz neben
#     der von der Aufgabenplanung verwalteten laufen liess. Zwei Prozesse
#     haben getrennten Arbeitsspeicher (getrennte $knownHashes) und wissen
#     nichts voneinander - beide hielten dieselbe neu hochgeladene Datei
#     fuer "noch nicht gesehen", kopierten sie gleichzeitig, und der
#     Namens-Kollisions-Fallback weiter unten (der eigentlich fuer echt
#     gleichnamige, aber inhaltlich unterschiedliche Dateien gedacht ist)
#     erzeugte dadurch eine exakte Doppelkopie unter "name_1.ext" - ein
#     Duplikat, obwohl die Hash-Pruefung an sich korrekt war. Eine simple
#     Datei-Sperre (exklusiv geoeffnet, nie geschlossen bis Prozessende)
#     verhindert das strukturell: eine zweite Instanz bekommt die Datei
#     nicht exklusiv geoeffnet und beendet sich sofort, statt eine Race
#     ueberhaupt erst zu riskieren. Kein Aufraeumen noetig - das Handle
#     faellt beim Prozessende (auch bei einem harten Kill) automatisch weg.
$lockPath = Join-Path $destRoot '.sync.lock'
try {
    $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
} catch {
    Write-Warning "Eine andere Instanz laeuft bereits (Sperrdatei $lockPath belegt) - beende mich sofort, um eine Daten-Race zu vermeiden."
    exit 1
}

# --- Fuer die Bildverarbeitung (HEIC-Dekodierung ueber den Windows-eigenen
#     HEIF-Codec + Skalierung, siehe Sync-Once) - auf der NAS selbst nicht
#     moeglich (ffmpeg/ImageMagick scheitern dort nachweislich an HEIC,
#     PHP hat keine imagick/gd-Extension geladen), deshalb macht das der
#     Laptop und schreibt das Ergebnis zusaetzlich auf die NAS zurueck. ---
Add-Type -AssemblyName PresentationCore
$preparedRoot = Join-Path (Split-Path $Source -Parent) 'Vorbereitet'
$maxEdgePx = 1920
$jpegQuality = 85

# --- Bestehenden Stand laden, damit ein Neustart des Skripts nicht wieder bei
#     Null anfaengt (nichts wird doppelt kopiert oder erneut gehasht). ---
$knownHashes = New-Object 'System.Collections.Generic.HashSet[string]'
$images = New-Object 'System.Collections.Generic.List[object]'
if (Test-Path $listJsonPath) {
    try {
        # WICHTIG: [object[]]$x = ... verwenden, NICHT $x = @(... | ConvertFrom-Json).
        # ConvertFrom-Json gibt sein Ergebnis als EIN Pipeline-Objekt aus statt die
        # Array-Elemente einzeln zu entrollen - @() sammelt dann nur dieses eine
        # emittierte Objekt ein und verpackt das ganze (bereits korrekte) Array
        # nochmal in ein 1-Element-Array. Live entdeckt: dadurch lud ein Neustart
        # nur 1 "Eintrag" (das gesamte alte Array als ein Objekt) statt der
        # tatsaechlichen Fotoliste - list.json wurde dadurch beim naechsten Save
        # auf einen Bruchteil der echten Fotos zusammengestutzt, obwohl die
        # Dateien selbst im Cache unangetastet blieben. [object[]]-Typzwang bei
        # der Zuweisung behandelt 0/1/N Elemente stattdessen korrekt.
        [object[]]$existing = Get-Content $listJsonPath -Raw | ConvertFrom-Json
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

        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)

        # Dekodieren, EXIF-/HEIF-Ausrichtung einrechnen, auf $maxEdgePx lange
        # Kante herunterskalieren (nie hochskalieren) und als JPEG
        # re-encodieren - Ergebnis zunaechst nur im Speicher, noch nicht auf
        # die Platte geschrieben.
        #
        # WICHTIG: der Duplikat-Hash wird jetzt ueber dieses VERARBEITETE
        # Ergebnis gebildet (reine Bilddaten, keine Metadaten mehr), nicht
        # mehr ueber die Rohdatei. Live gefunden, warum das noetig ist: zwei
        # Uploads von Ole (identischer Bildinhalt, ueber zwei Ordner wegen
        # des Leerzeichen-Tippfehlers) hatten unterschiedliche Rohdaten-
        # Hashes trotz gleicher Dateigroesse - JPEG-Metadaten (EXIF etc.)
        # sitzen typischerweise am ANFANG der Datei, nicht nur im Trailer
        # wie bei den Motion-Photo-Faellen (PXL_*.MP.jpg/.MP_1.jpg, siehe
        # Git-Historie) - ein reiner Tail-Ausschluss haette das verpasst.
        # Nach dem Dekodieren+Neuencodieren bleibt nur noch der reine
        # Bildinhalt uebrig, der Hash darueber ist deshalb zuverlaessiger.
        $outputBytes = $null
        try {
            $ms = New-Object System.IO.MemoryStream(, $bytes)
            $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
                $ms,
                [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            )
            $frame = $decoder.Frames[0]
            $bitmapSource = $frame

            # EXIF-/HEIF-Ausrichtung einrechnen: viele Handys speichern
            # Hochkant-Fotos als liegende Pixeldaten plus einem Dreh-Hinweis
            # in den Metadaten, den normale Bildbetrachter automatisch
            # anwenden - WPFs JpegBitmapEncoder tut das beim Re-Encodieren
            # aber NICHT von selbst, sonst waeren die Fotos im Ergebnis
            # seitlich/kopfueber. "System.Photo.Orientation" ist der
            # formatunabhaengige Windows-Property-Name, funktioniert sowohl
            # fuer klassisches EXIF (JPEG) als auch HEIF-Metadaten.
            $orientation = 1
            try {
                $ori = $frame.Metadata.GetQuery('System.Photo.Orientation')
                if ($ori) { $orientation = [int]$ori }
            } catch {}

            if ($orientation -ne 1) {
                $rotGroup = New-Object System.Windows.Media.TransformGroup
                switch ($orientation) {
                    2 { $rotGroup.Children.Add((New-Object System.Windows.Media.ScaleTransform(-1, 1))) }
                    3 { $rotGroup.Children.Add((New-Object System.Windows.Media.RotateTransform(180))) }
                    4 { $rotGroup.Children.Add((New-Object System.Windows.Media.ScaleTransform(1, -1))) }
                    5 { $rotGroup.Children.Add((New-Object System.Windows.Media.ScaleTransform(-1, 1))); $rotGroup.Children.Add((New-Object System.Windows.Media.RotateTransform(90))) }
                    6 { $rotGroup.Children.Add((New-Object System.Windows.Media.RotateTransform(90))) }
                    7 { $rotGroup.Children.Add((New-Object System.Windows.Media.ScaleTransform(-1, 1))); $rotGroup.Children.Add((New-Object System.Windows.Media.RotateTransform(270))) }
                    8 { $rotGroup.Children.Add((New-Object System.Windows.Media.RotateTransform(270))) }
                }
                if ($rotGroup.Children.Count -gt 0) {
                    $rotated = New-Object System.Windows.Media.Imaging.TransformedBitmap
                    $rotated.BeginInit()
                    $rotated.Source = $frame
                    $rotated.Transform = $rotGroup
                    $rotated.EndInit()
                    $bitmapSource = $rotated
                }
            }

            # Skalierung NACH der Rotation berechnen - bei 90/270 Grad sind
            # Breite und Hoehe vertauscht, $bitmapSource.PixelWidth/Height
            # spiegelt das an dieser Stelle schon korrekt wider.
            $longEdge = [Math]::Max($bitmapSource.PixelWidth, $bitmapSource.PixelHeight)
            if ($longEdge -gt $maxEdgePx) {
                $scale = $maxEdgePx / $longEdge
                $scaled = New-Object System.Windows.Media.Imaging.TransformedBitmap
                $scaled.BeginInit()
                $scaled.Source = $bitmapSource
                $scaled.Transform = New-Object System.Windows.Media.ScaleTransform($scale, $scale)
                $scaled.EndInit()
                $bitmapSource = $scaled
            }
            $encoder = New-Object System.Windows.Media.Imaging.JpegBitmapEncoder
            $encoder.QualityLevel = $jpegQuality
            $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmapSource))
            $outMs = New-Object System.IO.MemoryStream
            $encoder.Save($outMs)
            $outputBytes = $outMs.ToArray()
            $outMs.Dispose()
            $ms.Dispose()
        } catch {
            Write-Warning "$(Get-Date -Format 'HH:mm:ss')  Konnte $relSource nicht dekodieren/skalieren, verwende Original: $_"
        }

        if ($outputBytes) {
            $bodyLength = $outputBytes.Length
        } else {
            # Fallback: unverarbeitetes Original (seltenes/beschaedigtes
            # Format) - dafuer weiterhin Tail-Ausschluss beim Hash, da hier
            # keine bereinigte Version existiert, ueber die man stattdessen
            # gehen koennte (Begruendung siehe oben).
            $outputBytes = $bytes
            $tailMargin = 8192
            $bodyLength = if ($outputBytes.Length -gt $tailMargin) { $outputBytes.Length - $tailMargin } else { $outputBytes.Length }
        }

        try {
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            try {
                $hashBytes = $sha256.ComputeHash($outputBytes, 0, $bodyLength)
            } finally {
                $sha256.Dispose()
            }
            $hash = [BitConverter]::ToString($hashBytes) -replace '-', ''
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

        # Zielname = kompletter Originalname + ".jpg" angehaengt (nicht die
        # Endung ersetzt), z.B. "IMG_0927.HEIC" -> "IMG_0927.HEIC.jpg" - dank
        # dem eindeutigen Original-Dateinamen automatisch kollisionsfrei,
        # keine _1/_2-Zaehllogik noetig. Wichtig auch fuer list.php: die kann
        # denselben Namen dadurch aus dem Original vorhersagen, ohne die
        # Kopierreihenfolge zu kennen.
        $destName = "$($f.Name).jpg"
        $destPath = Join-Path $destUserDir $destName
        [System.IO.File]::WriteAllBytes($destPath, $outputBytes)

        [void]$knownHashes.Add($hash)
        $manifest[$manifestKey] = @{ size = $f.Length; mtime = $mtimeTicks; status = 'copied'; hash = $hash }

        # Gleiches Ergebnis zusaetzlich auf die NAS zurueckschreiben, damit
        # list.php (Fire-TV-Stick/Online-Pfad) ebenfalls das schlanke,
        # vorbereitete Bild ausliefern kann statt des Rohformats. Bewusst
        # nicht fatal: ein kurzer NAS-Schreibfehler darf den lokalen Cache
        # nicht blockieren.
        try {
            $preparedUserDir = Join-Path $preparedRoot $user
            if (-not (Test-Path $preparedUserDir)) { New-Item -ItemType Directory -Path $preparedUserDir -Force | Out-Null }
            [System.IO.File]::WriteAllBytes((Join-Path $preparedUserDir $destName), $outputBytes)
        } catch {
            Write-Warning "$(Get-Date -Format 'HH:mm:ss')  Konnte vorbereitetes Bild nicht auf NAS zurueckschreiben ($relSource): $_"
        }

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

# --- Lokaler statischer Webserver als eigener Runspace im selben Prozess
#     (NICHT als Start-Job-Kindprozess - siehe Begruendung unten) mit zwei
#     Wurzeln: $root (nas-slideshow/ im Repo - slideshow.html,
#     libheif-bundle.js) fuer alles, und $destRoot (Downloads/... - Bilder +
#     list.json) fuer alles unter "/cache/". Browser blockieren fetch() auf
#     file://, daher noetig - bewusst per HttpListener in reinem PowerShell
#     gebaut statt z.B. python -m http.server, damit auf dem Beamer-Laptop
#     nichts installiert sein muss ausser Windows selbst.
#
#     Start-Job wurde ausgetauscht, weil es unter der Aufgabenplanung
#     (versteckt, nicht-interaktiv, siehe install-autostart.ps1) beobachtet
#     wurde, seinen Kindprozess manchmal gar nicht erst zu starten - ohne
#     jede Fehlermeldung, der Sync lief normal weiter, nur Port 8090 blieb
#     unbelegt. Ein Runspace laeuft als Thread im selben Prozess statt als
#     separater Kindprozess: kann unter dieser Bedingung nicht "verloren
#     gehen" und stirbt automatisch mit, wenn der Hauptprozess endet. ---
$serverScript = {
    param($root, $cacheRoot, $port, $allowRemote)

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
    # "+" bindet auf allen Netzwerkschnittstellen statt nur localhost - noetig
    # damit z.B. ein per VPN eingewaehltes Geraet den Server erreicht. Braucht
    # vorab einmalig "netsh http add urlacl" + eine Firewall-Freigabe (siehe
    # -AllowRemote Hilfetext), sonst schlaegt Start() weiter unten fehl.
    $prefix = if ($allowRemote) { "http://+:$port/" } else { "http://localhost:$port/" }
    $listener.Prefixes.Add($prefix)

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
                Write-Warning "SERVER-FEHLER: konnte Port $port nach $attempt Versuchen nicht oeffnen ($_). Ggf. als Administrator: netsh http add urlacl url=http://localhost:$port/ user=$env:USERNAME"
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
}

$serverRunspace = [runspacefactory]::CreateRunspace()
$serverRunspace.Open()
$serverPs = [powershell]::Create()
$serverPs.Runspace = $serverRunspace
[void]$serverPs.AddScript($serverScript).AddArgument($root).AddArgument($destRoot).AddArgument($Port).AddArgument($AllowRemote.IsPresent)
$serverHandle = $serverPs.BeginInvoke()

Start-Sleep -Milliseconds 700
foreach ($w in $serverPs.Streams.Warning) { Write-Warning $w.Message }

Write-Host "======================================================"
Write-Host " Diashow lokal: http://localhost:$Port/slideshow.html"
if ($AllowRemote) {
    $lanIps = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' }).IPAddress
    foreach ($ip in $lanIps) { Write-Host " Auch erreichbar: http://${ip}:$Port/slideshow.html" }
}
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
    try { $serverPs.Stop() } catch {}
    $serverPs.Dispose()
    $serverRunspace.Close()
    $serverRunspace.Dispose()
    $lockStream.Dispose()
}
