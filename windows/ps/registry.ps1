# Registre : uniquement les entrées orphelines certaines (programme ou fichier
# visé introuvable). Chaque suppression est sauvegardée (.reg ou valeur) et
# peut être annulée.
$backup = Join-Path $env:BAO_DATA 'sauvegardes'
function ExeOf([string]$cmd) {
  if (-not $cmd) { return '' }
  $c = [Environment]::ExpandEnvironmentVariables($cmd.Trim())
  if ($c.StartsWith('"')) { $e = $c.IndexOf('"', 1); if ($e -gt 0) { return $c.Substring(1, $e - 1) } }
  $m = [regex]::Match($c, '^(.+?\.(exe|dll|cmd|bat))(\s|,|$)', 'IgnoreCase')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}
# chemin absolu sur un disque local et absent (les chemins réseau ou relatifs ne comptent pas)
function Missing([string]$p) { return ($p -match '^[A-Za-z]:\\' -and -not (Test-Path -LiteralPath $p)) }
function RegPath([string]$ps) { return ($ps -replace '^HKLM:', 'HKEY_LOCAL_MACHINE' -replace '^HKCU:', 'HKEY_CURRENT_USER') }

if ($A.action -eq 'restore') {
  foreach ($v in @($A.values)) {
    if (-not $v) { continue }
    if (-not (Test-Path -LiteralPath $v.key)) { New-Item -Path $v.key -Force | Out-Null }
    $val = if ($v.type -eq 'Binary') { [byte[]]$v.value } elseif ($v.type -eq 'MultiString') { [string[]]$v.value } else { $v.value }
    New-ItemProperty -LiteralPath $v.key -Name $v.name -Value $val -PropertyType $v.type -Force | Out-Null
  }
  foreach ($f in @($A.files)) { if ($f) { & "$env:SystemRoot\System32\reg.exe" import "$f" 2>&1 | Out-Null } }
  Out-Json @{ ok = $true }; return
}

if ($A.action -eq 'fix') {
  New-Item -ItemType Directory -Force -Path $backup | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $values = @(); $files = @(); $n = 0
  foreach ($i in $A.items) {
    try {
      if ($i.value) {
        $k = Get-Item -LiteralPath $i.key
        $values += , @{ key = $i.key; name = $i.value; type = $k.GetValueKind($i.value).ToString(); value = $k.GetValue($i.value, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
        Remove-ItemProperty -LiteralPath $i.key -Name $i.value
      } else {
        $f = Join-Path $backup ("registre-$stamp-$n.reg")
        & "$env:SystemRoot\System32\reg.exe" export (RegPath $i.key) "$f" /y 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $files += $f
        Remove-Item -LiteralPath $i.key -Recurse -Force
      }
      $n++
    } catch {}
  }
  Out-Json @{ ok = $true; fixed = $n; detail = "$n entrées retirées, sauvegardées dans $backup"; undo = @{ script = 'registry'; args = @{ action = 'restore'; values = $values; files = $files } } }
  return
}

# analyse
$items = New-Object System.Collections.ArrayList
function Add($cat, $key, $value, $detail) { [void]$items.Add([ordered]@{ cat = $cat; key = $key; value = $value; detail = $detail }) }

foreach ($r in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
  if (-not (Test-Path -LiteralPath $r)) { continue }
  $k = Get-Item -LiteralPath $r
  foreach ($n in $k.GetValueNames()) { if (-not $n) { continue }; $exe = ExeOf ([string]$k.GetValue($n)); if (Missing $exe) { Add 'run' $r $n "Lance $exe, qui n'existe plus" } }
}
foreach ($u in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall') {
  if (-not (Test-Path -LiteralPath $u)) { continue }
  foreach ($s in Get-ChildItem -LiteralPath $u -ErrorAction SilentlyContinue) {
    $v = Get-ItemProperty -LiteralPath $s.PSPath -ErrorAction SilentlyContinue
    if (-not $v.DisplayName -or -not $v.UninstallString) { continue }
    if ($v.UninstallString -match 'msiexec') { continue } # géré par Windows Installer
    $exe = ExeOf ([string]$v.UninstallString)
    $loc = [string]$v.InstallLocation
    if ((Missing $exe) -and (-not $loc -or (Missing $loc))) { Add 'uninstall' ($u + '\' + $s.PSChildName) $null "« $($v.DisplayName) » : désinstallateur introuvable ($exe)" }
  }
}
foreach ($ap in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths') {
  if (-not (Test-Path -LiteralPath $ap)) { continue }
  foreach ($s in Get-ChildItem -LiteralPath $ap -ErrorAction SilentlyContinue) {
    $exe = ([string]$s.GetValue('')).Trim('"')
    if ($exe -and (Missing ([Environment]::ExpandEnvironmentVariables($exe)))) { Add 'apppaths' ($ap + '\' + $s.PSChildName) $null "$($s.PSChildName) → $exe introuvable" }
  }
}
foreach ($sd in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedDLLs', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\SharedDLLs') {
  if (-not (Test-Path -LiteralPath $sd)) { continue }
  $k = Get-Item -LiteralPath $sd
  foreach ($n in $k.GetValueNames()) { if ($n -and (Missing $n)) { Add 'shareddlls' $sd $n "Compteur pour $n, fichier disparu" } }
}
$base = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
foreach ($pair in @(@('HKCU', 'Run', 'Software\Microsoft\Windows\CurrentVersion\Run'), @('HKLM', 'Run', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'), @('HKLM', 'Run32', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'))) {
  $ak = "$($pair[0]):\$base\$($pair[1])"; $rk = "$($pair[0]):\$($pair[2])"
  if (-not (Test-Path -LiteralPath $ak)) { continue }
  $names = if (Test-Path -LiteralPath $rk) { (Get-Item -LiteralPath $rk).GetValueNames() } else { @() }
  foreach ($n in (Get-Item -LiteralPath $ak).GetValueNames()) { if ($n -and $names -notcontains $n) { Add 'approved' $ak $n "État de démarrage de « $n », programme retiré" } }
}
Out-Json @{ items = $items }
