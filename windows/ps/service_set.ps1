# Change le type de démarrage d'un service (auto, delayed-auto, demand,
# disabled), l'arrête ou le démarre. Renvoie de quoi revenir en arrière.
$protected = 'RpcSs', 'RpcEptMapper', 'DcomLaunch', 'LSM', 'Winmgmt', 'EventLog', 'PlugPlay', 'Power', 'ProfSvc', 'SamSs', 'Schedule', 'gpsvc', 'CryptSvc', 'BFE', 'mpssvc', 'WinDefend', 'SecurityHealthService', 'wscsvc', 'Dhcp', 'Dnscache', 'nsi', 'NlaSvc', 'netprofm', 'AudioSrv', 'AudioEndpointBuilder', 'BrokerInfrastructure', 'CoreMessagingRegistrar', 'StateRepository', 'SystemEventsBroker', 'TimeBrokerSvc', 'UserManager', 'Themes', 'TrustedInstaller', 'wuauserv', 'UsoSvc', 'msiserver', 'VaultSvc', 'KeyIso', 'Appinfo', 'AppXSvc', 'ClipSVC', 'camsvc', 'DeviceInstall', 'DispBrokerDesktopSvc', 'LanmanWorkstation', 'WlanSvc', 'Wcmsvc', 'EFS', 'sppsvc', 'Sense', 'WdNisSvc', 'TokenBroker', 'seclogon', 'tiledatamodelsvc', 'FontCache', 'ShellHWDetection'
$n = [string]$A.name
if ($protected -contains $n -and -not $A.undo) { throw "Service essentiel de Windows : modification bloquée par la Boîte à outils." }
$s = Get-CimInstance Win32_Service -Filter ("Name='" + ($n -replace "'", "''") + "'")
if (-not $s) { throw "Service introuvable : $n" }
if ($A.restart) { Restart-Service -Name $n -Force -ErrorAction Stop; Out-Json @{ ok = $true }; return }
$map = @{ Auto = 'auto'; Manual = 'demand'; Disabled = 'disabled'; Boot = 'boot'; System = 'system' }
$prevStart = if ($s.StartMode -eq 'Auto' -and $s.DelayedAutoStart) { 'delayed-auto' } else { $map[[string]$s.StartMode] }
$wasRunning = $s.State -eq 'Running'
if ($A.start -and $A.start -ne $prevStart) {
  $out = & "$env:SystemRoot\System32\sc.exe" config "$n" start= $A.start 2>&1
  if ($LASTEXITCODE -ne 0) {
    if ($LASTEXITCODE -eq 5) { throw "Accès refusé : ce service est protégé par Windows ou par son éditeur." }
    throw ("Échec de la modification (code $LASTEXITCODE)")
  }
}
if ($A.stop -and $wasRunning) { Stop-Service -Name $n -Force -ErrorAction Stop }
if ($A.run -and -not $wasRunning) { Start-Service -Name $n -ErrorAction Stop }
$undo = @{ script = 'service_set'; args = @{ name = $n; start = $prevStart; run = [bool]($wasRunning -and $A.stop); stop = [bool]((-not $wasRunning) -and $A.run); undo = $true } }
Out-Json @{ ok = $true; detail = "$($s.DisplayName) ($n) : $prevStart → $($A.start)"; undo = $undo }
