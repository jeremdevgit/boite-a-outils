# Programmes lancés au démarrage : clés Run, dossiers Démarrage, tâches planifiées.
# État activé/désactivé lu comme le Gestionnaire des tâches (StartupApproved).
function ExeOf([string]$cmd) {
  if (-not $cmd) { return '' }
  $c = [Environment]::ExpandEnvironmentVariables($cmd.Trim())
  if ($c.StartsWith('"')) { $e = $c.IndexOf('"', 1); if ($e -gt 0) { return $c.Substring(1, $e - 1) } }
  $m = [regex]::Match($c, '^(.+?\.(exe|cmd|bat|com|vbs|ps1|scr))(\s|$)', 'IgnoreCase')
  if ($m.Success) { return $m.Groups[1].Value }
  return ($c -split ' ')[0]
}
function Meta([string]$exe) {
  $r = @{ exists = $false; company = ''; product = ''; description = '' }
  if ($exe -and $exe -notmatch '\\') { $r.exists = $true; return $r } # nom seul (rundll32…) : résolu par le PATH
  if ($exe -and (Test-Path -LiteralPath $exe -PathType Leaf)) {
    $r.exists = $true
    try { $vi = (Get-Item -LiteralPath $exe).VersionInfo; $r.company = [string]$vi.CompanyName; $r.product = [string]$vi.ProductName; $r.description = [string]$vi.FileDescription } catch {}
  }
  return $r
}
$base = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
function Approved($hive, $sub, $name) {
  try {
    $b = (Get-ItemProperty -LiteralPath "$($hive):\$base\$sub" -Name $name -ErrorAction Stop).$name
    if ($b -is [byte[]] -and $b.Length -gt 0) { return (($b[0] -band 1) -eq 0) }
  } catch {}
  return $true
}
$items = New-Object System.Collections.ArrayList
$runs = @(
  @{ hive = 'HKCU'; key = 'Software\Microsoft\Windows\CurrentVersion\Run'; ap = 'Run'; scope = 'Cet utilisateur' },
  @{ hive = 'HKLM'; key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; ap = 'Run'; scope = 'Tous les utilisateurs' },
  @{ hive = 'HKLM'; key = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; ap = 'Run32'; scope = 'Tous les utilisateurs' }
)
foreach ($r in $runs) {
  $p = "$($r.hive):\$($r.key)"
  if (-not (Test-Path -LiteralPath $p)) { continue }
  $k = Get-Item -LiteralPath $p
  foreach ($n in $k.GetValueNames()) {
    if (-not $n) { continue }
    $cmd = [string]$k.GetValue($n, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $exe = ExeOf $cmd; $m = Meta $exe
    [void]$items.Add([ordered]@{ kind = 'run'; id = "$($r.hive)|$($r.key)|$n"; hive = $r.hive; key = $r.key; ap = $r.ap; name = $n; command = $cmd; exe = $exe; exists = $m.exists; company = $m.company; product = $m.product; description = $m.description; enabled = (Approved $r.hive $r.ap $n); scope = $r.scope; location = "$($r.hive)\$($r.key)" })
  }
}
$sh = New-Object -ComObject WScript.Shell
$folders = @(
  @{ dir = [Environment]::GetFolderPath('Startup'); hive = 'HKCU'; scope = 'Cet utilisateur' },
  @{ dir = [Environment]::GetFolderPath('CommonStartup'); hive = 'HKLM'; scope = 'Tous les utilisateurs' }
)
foreach ($f in $folders) {
  if (-not $f.dir -or -not (Test-Path -LiteralPath $f.dir)) { continue }
  foreach ($file in Get-ChildItem -LiteralPath $f.dir -File -Force) {
    if ($file.Name -eq 'desktop.ini') { continue }
    $exe = $file.FullName; $cmd = $file.FullName
    if ($file.Extension -eq '.lnk') { try { $l = $sh.CreateShortcut($file.FullName); if ($l.TargetPath) { $exe = $l.TargetPath; $cmd = ('"' + $l.TargetPath + '" ' + $l.Arguments).Trim() } } catch {} }
    $m = Meta $exe
    [void]$items.Add([ordered]@{ kind = 'folder'; id = "$($f.hive)|$($file.FullName)"; hive = $f.hive; path = $file.FullName; name = $file.BaseName; command = $cmd; exe = $exe; exists = $m.exists; company = $m.company; product = $m.product; description = $m.description; enabled = (Approved $f.hive 'StartupFolder' $file.Name); scope = $f.scope; location = $f.dir })
  }
}
foreach ($t in Get-ScheduledTask) {
  $ms = $t.TaskPath -like '\Microsoft\*'
  if ($ms -and -not $A.windows) { continue }
  $act = $t.Actions | Select-Object -First 1
  $exe = ''; $cmd = ''
  if ($act -and $act.Execute) { $exe = [Environment]::ExpandEnvironmentVariables(([string]$act.Execute).Trim('"')); $cmd = ('"' + $exe + '" ' + $act.Arguments).Trim() }
  elseif ($act) { $cmd = '(composant COM)' }
  $trig = @($t.Triggers | ForEach-Object { $_.CimClass.CimClassName -replace '^MSFT_Task', '' -replace 'Trigger$', '' })
  $m = if ($exe) { Meta $exe } else { @{ exists = $true; company = ''; product = ''; description = '' } }
  $desc = if ($t.Description -and $t.Description -notlike '$(@*') { [string]$t.Description } else { $m.description }
  [void]$items.Add([ordered]@{ kind = 'task'; id = "$($t.TaskPath)$($t.TaskName)"; taskPath = $t.TaskPath; name = $t.TaskName; command = $cmd; exe = $exe; exists = $m.exists; company = $m.company; product = $m.product; description = $desc; enabled = ($t.State -ne 'Disabled'); state = [string]$t.State; triggers = $trig; author = [string]$t.Author; microsoft = $ms; location = $t.TaskPath })
}
Out-Json @{ items = $items }
