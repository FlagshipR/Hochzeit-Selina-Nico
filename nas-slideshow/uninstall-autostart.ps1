<#
.SYNOPSIS
  Entfernt die von install-autostart.ps1 eingerichtete Aufgabenplanung wieder
  (stoppt den laufenden Sync/Server-Prozess falls aktiv und loescht die
  Aufgabe). Der lokale Foto-Cache in Downloads\Hochzeitsfotos-Cache bleibt
  unangetastet.
#>

$ErrorActionPreference = 'Stop'
$taskName = 'Hochzeit-Slideshow-Sync'

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $task) {
    "Keine Aufgabe '$taskName' gefunden - nichts zu tun."
    return
}

Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
"Aufgabe '$taskName' entfernt. Falls run-local.ps1 gerade noch laeuft (z.B. manuell gestartet), bitte das jeweilige Fenster separat schliessen."
