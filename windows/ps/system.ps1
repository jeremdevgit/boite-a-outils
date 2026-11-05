# Informations système pour l'accueil, et quelques actions simples
# (cache d'optimisation de la distribution, mise en veille prolongée).
switch ($A.action) {
  'clearDelivery' { try { Delete-DeliveryOptimizationCache -Force } catch {}; Out-Json @{ ok = $true }; return }
  'hibernate' {
    $was = Test-Path -LiteralPath "$env:SystemDrive\hiberfil.sys"
    & "$env:SystemRoot\System32\powercfg.exe" /hibernate $(if ($A.on) { 'on' } else { 'off' }) 2>&1 | Out-Null
    Out-Json @{ ok = $true; detail = "Veille prolongée : $(if ($A.on) { 'activée' } else { 'désactivée' })"; undo = @{ script = 'system'; args = @{ action = 'hibernate'; on = $was } } }
    return
  }
  'leftovers' {
    # dossiers d'applications qui ne correspondent plus à aucun programme installé
    $norm = { param($s) ([string]$s).ToLower() -replace '[^a-z0-9]', '' }
    $tokens = New-Object System.Collections.Generic.HashSet[string]
    # nom entier, puis chaque mot de 4 lettres et plus (« RobloxGDK » → roblox, gdk)
    $add = { param($s) $n = & $norm $s; if ($n.Length -ge 3) { [void]$tokens.Add($n) }; foreach ($w in ([string]$s -creplace '([a-z])([A-Z])', '$1 $2' -split '[^A-Za-z0-9]+')) { if ($w.Length -ge 4) { [void]$tokens.Add($w.ToLower()) } } }
    foreach ($u in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall') {
      foreach ($s in Get-ChildItem -LiteralPath $u -ErrorAction SilentlyContinue) {
        $v = Get-ItemProperty -LiteralPath $s.PSPath -ErrorAction SilentlyContinue
        & $add $v.DisplayName; & $add $v.Publisher; & $add $s.PSChildName
        if ($v.InstallLocation) { & $add (Split-Path ([string]$v.InstallLocation).TrimEnd('\') -Leaf) }
      }
    }
    foreach ($p in Get-AppxPackage -ErrorAction SilentlyContinue) { & $add $p.Name; foreach ($w in ($p.Name -split '\.')) { & $add $w } }
    $used = @()
    foreach ($p in Get-Process -ErrorAction SilentlyContinue) { try { if ($p.Path) { $used += $p.Path.ToLower() } } catch {} }
    # services et pilotes (un pilote peut vivre dans Program Files)
    foreach ($s in @(Get-CimInstance Win32_Service) + @(Get-CimInstance Win32_SystemDriver)) { if ($s.PathName) { $used += ([Environment]::ExpandEnvironmentVariables(([string]$s.PathName).Trim('"')) -replace '^\\\?\?\\', '').ToLower() } }
    foreach ($t in Get-ScheduledTask) { foreach ($a in $t.Actions) { if ($a.Execute) { $used += ([Environment]::ExpandEnvironmentVariables([string]$a.Execute)).Trim('"').ToLower() } } }
    $skip = 'microsoft', 'windows', 'commonfiles', 'packages', 'temp', 'windowsapps', 'microsoftnet', 'internetexplorer', 'windowsdefender', 'windowsmail', 'windowsmediaplayer', 'windowsnt', 'windowsphotoviewer', 'windowspowershell', 'modifiablewindowsapps', 'uninstallinformation', 'referenceassemblies', 'msbuild', 'dotnet', 'packagecache', 'comms', 'connecteddevicesplatform', 'd3dscache', 'crashdumps', 'peerdistrepub', 'programs', 'publishers', 'applicationdata', 'usoshared', 'usoprivate', 'ssh', 'softwaredistribution', 'regid199106commicrosoft', 'desktop', 'documents', 'startmenu', 'templates', 'favorites', 'history', 'virtualstore', 'ssl', 'mozilla', 'google', 'nvidia', 'nvidiacorporation', 'intel', 'amd', 'realtek', 'package', 'cache', 'logs', 'fonts', 'identities', 'adobe', 'apple', 'sun', 'oracle', 'java', 'python', 'npm', 'npmcache', 'pip', 'nuget', 'gitkraken', 'vlc', 'igd', 'bin', 'lib', 'tools', 'data', 'updates', 'setup', 'placeholdertilelogofolder', 'aspnet', 'fontconfig', 'squirreltemp', 'tmp', 'deliveryoptimization', 'speech', 'speechvoices', 'ssh', 'gnupg', 'jupyter', 'pip', 'rust', 'cargo', 'rustup', 'node', 'yarn', 'pnpm', 'electron', 'electronbuilder', 'npmcache', 'gitkraken', 'docker', 'programsdata', 'mui', 'servicing'
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA) | Where-Object { $_ }
    $limit = (Get-Date).AddDays(-60)
    $out = New-Object System.Collections.ArrayList
    foreach ($r in $roots) {
      foreach ($d in Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue) {
        if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $n = & $norm $d.Name
        if ($n.Length -lt 3 -or $skip -contains $n) { continue }
        $match = $false
        foreach ($t in $tokens) { if ($t.Contains($n) -or ($t.Length -ge 4 -and $n.Contains($t))) { $match = $true; break } }
        if ($match) { continue }
        $full = $d.FullName.ToLower() + '\'
        if ($used | Where-Object { $_.StartsWith($full) } | Select-Object -First 1) { continue }
        # activité récente (le dossier sert encore) ou programme présent (exécutable,
        # bibliothèque, pilote : peut-être un logiciel portable ou un pilote installé)
        $keep = Get-ChildItem -LiteralPath $d.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $limit -or $_.Extension -match '^\.(exe|dll|sys|msi|jar)$' } | Select-Object -First 1
        if ($keep) { continue }
        [void]$out.Add([ordered]@{ path = $d.FullName; root = $r; modified = $d.LastWriteTime.ToString('o') })
      }
    }
    Out-Json @{ items = $out }; return
  }
}
# vue d'ensemble pour l'accueil
$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
$gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Virtual|Remote|Meta|Parsec|Basic' } | ForEach-Object { $_.Name })
$hiber = Get-Item -LiteralPath "$env:SystemDrive\hiberfil.sys" -Force -ErrorAction SilentlyContinue
$page = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | Select-Object -First 1
$plan = ((& "$env:SystemRoot\System32\powercfg.exe" /getactivescheme) -join ' ') -replace '^.*\(|\)\s*$', ''
$def = $null
try { $m = Get-MpComputerStatus -ErrorAction Stop; $def = @{ realtime = [bool]$m.RealTimeProtectionEnabled; signatures = $m.AntivirusSignatureLastUpdated.ToString('o') } } catch {}
Out-Json @{
  os = "$($os.Caption) $($cv.DisplayVersion)"; build = "$($cv.CurrentBuild).$($cv.UBR)"; boot = $os.LastBootUpTime.ToString('o')
  cpu = $cpu; gpus = $gpus; hiberfil = $(if ($hiber) { $hiber.Length } else { 0 }); pagefile = $(if ($page) { [int64]$page.AllocatedBaseSize * 1MB } else { 0 })
  plan = $plan; defender = $def
}
