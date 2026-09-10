<#
.SYNOPSIS
  Richtet eine Windows-Aufgabenplanung ein, die run-local.ps1 automatisch bei
  jedem Login startet (versteckt im Hintergrund) und dort dauerhaft laufen
  laesst - kein manuelles Oeffnen von PowerShell mehr noetig. Einmal auf dem
  Beamer-Laptop ausfuehren, danach synct/serviert es sich von selbst.

  Laeuft auch im Akkubetrieb weiter (wichtig, falls der Laptop am
  Hochzeitstag nicht durchgehend am Netz haengt) und hat kein Zeitlimit
  (Task Scheduler wuerde eine Dauerschleife sonst nach 3 Tagen killen).

.PARAMETER AllowRemote
  Reicht -AllowRemote an run-local.ps1 durch (Server auch im (V)LAN
  erreichbar, nicht nur von diesem Rechner selbst) - siehe dessen eigene
  Hilfe fuer die noetigen einmaligen Admin-Schritte (netsh urlacl +
  Firewall-Freigabe), OHNE die klappt auch dieser Schalter nicht.

.EXAMPLE
  .\install-autostart.ps1
  .\install-autostart.ps1 -AllowRemote
  .\uninstall-autostart.ps1   # zum Rueckgaengigmachen
#>
param(
    [switch]$AllowRemote
)

$ErrorActionPreference = 'Stop'
$taskName = 'Hochzeit-Slideshow-Sync'
$scriptPath = Join-Path $PSScriptRoot 'run-local.ps1'
$logPath = Join-Path $env:USERPROFILE 'Downloads\Hochzeitsfotos-Sync.log'
$remoteArg = if ($AllowRemote) { ' -AllowRemote' } else { '' }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -Command `"& '$scriptPath'$remoteArg *>&1 | Out-File -FilePath '$logPath' -Append -Encoding utf8`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Synct Hochzeitsfotos von der NAS (Dedup per Hash) und stellt die lokale Diashow unter http://localhost:8090/slideshow.html bereit. Von run-local.ps1 / install-autostart.ps1 in nas-slideshow eingerichtet.' `
    -Force | Out-Null

# Gleich auch jetzt starten, nicht erst beim naechsten Login.
Start-ScheduledTask -TaskName $taskName

Start-Sleep -Seconds 2
$task = Get-ScheduledTask -TaskName $taskName
$info = Get-ScheduledTaskInfo -TaskName $taskName

Write-Host "======================================================"
Write-Host " Eingerichtet: '$taskName'"
Write-Host " Status:       $($task.State)"
Write-Host " Letzter Start: $($info.LastRunTime)"
Write-Host " Laeuft ab jetzt bei jedem Login automatisch im Hintergrund."
Write-Host " Diashow:      http://localhost:8090/slideshow.html"
Write-Host " Log-Datei:    $logPath"
Write-Host " Deinstallieren: .\uninstall-autostart.ps1"
Write-Host "======================================================"
