# Programmes installés (Programmes et fonctionnalités) et lancement de leur
# désinstallateur officiel. Seule une commande présente dans le registre peut
# être lancée.
$keys = @(
  @{ p = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; scope = 'Tous' },
  @{ p = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; scope = 'Tous (32 bits)' },
  @{ p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'; scope = 'Cet utilisateur' }
)
function All {
  foreach ($k in $keys) {
    if (-not (Test-Path -LiteralPath $k.p)) { continue }
    foreach ($s in Get-ChildItem -LiteralPath $k.p -ErrorAction SilentlyContinue) {
      $v = Get-ItemProperty -LiteralPath $s.PSPath -ErrorAction SilentlyContinue
      if (-not $v.DisplayName -or $v.SystemComponent -eq 1 -or $v.ParentKeyName -or $v.ReleaseType -match 'Update|Hotfix') { continue }
      [ordered]@{ key = $s.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''; name = [string]$v.DisplayName; publisher = [string]$v.Publisher; version = [string]$v.DisplayVersion; date = [string]$v.InstallDate; size = [int64]($v.EstimatedSize) * 1024; location = [string]$v.InstallLocation; uninstall = [string]$v.UninstallString; quiet = [string]$v.QuietUninstallString; icon = [string]$v.DisplayIcon; scope = $k.scope; url = [string]$(if ($v.URLUpdateInfo) { $v.URLUpdateInfo } elseif ($v.URLInfoAbout) { $v.URLInfoAbout } else { $v.HelpLink }) }
    }
  }
}
if ($A.action -eq 'stop') {
  # ferme les processus lancés depuis le dossier d'installation du programme
  $p = All | Where-Object { $_.key -eq $A.key } | Select-Object -First 1
  $loc = ([string]$p.location).Trim('"').TrimEnd('\').ToLower()
  # jamais un dossier qui contient d'autres programmes (racine, Windows, Program Files, profil)
  $roots = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, "$env:LOCALAPPDATA\Programs") | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLower() }
  if ($loc.Length -lt 8 -or $loc -match '^[a-z]:$' -or $roots -contains $loc -or $loc.StartsWith($env:SystemRoot.ToLower())) { throw "Emplacement du programme inconnu" }
  $n = 0
  foreach ($x in Get-Process -ErrorAction SilentlyContinue) { try { if ($x.Path -and $x.Path.ToLower().StartsWith("$loc\")) { Stop-Process -Id $x.Id -Force -ErrorAction Stop; $n++ } } catch {} }
  Out-Json @{ ok = $true; stopped = $n }; return
}
if ($A.action -eq 'uninstall') {
  $p = All | Where-Object { $_.key -eq $A.key } | Select-Object -First 1
  if (-not $p -or -not $p.uninstall) { throw "Programme introuvable ou sans désinstallateur" }
  $cmd = $p.uninstall
  # MSI : /I ouvre parfois la réparation ; /X désinstalle
  if ($cmd -match '^\s*"?msiexec(\.exe)?"?\s+/I\s*(\{[0-9A-F-]+\})') { $cmd = "MsiExec.exe /X$($Matches[2])" }
  Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/d', '/c', "`"$cmd`"" -WindowStyle Hidden
  Out-Json @{ ok = $true; started = $cmd }; return
}
Out-Json @{ items = @(All) }
