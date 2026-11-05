# Jeux installés et leur plateforme : lu dans les manifestes de chaque lanceur.
$out = New-Object System.Collections.ArrayList
function Add-Game($name, $platform, $path) { if ($name) { [void]$out.Add([ordered]@{ name = [string]$name; platform = $platform; path = [string]$path }) } }
$reg = { param($p) Get-ItemProperty -Path $p -ErrorAction SilentlyContinue }

# Steam : bibliothèques de libraryfolders.vdf, puis appmanifest_*.acf
$steam = (& $reg 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam').InstallPath
if (-not $steam) { $steam = (& $reg 'HKCU:\Software\Valve\Steam').SteamPath }
if ($steam -and (Test-Path -LiteralPath $steam)) {
  $libs = @($steam)
  $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
  if (Test-Path -LiteralPath $vdf) { foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += $m.Groups[1].Value -replace '\\\\', '\' } }
  foreach ($l in ($libs | Sort-Object -Unique)) {
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $l 'steamapps') -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
      $t = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
      $n = [regex]::Match($t, '"name"\s+"([^"]+)"').Groups[1].Value
      $d = [regex]::Match($t, '"installdir"\s+"([^"]+)"').Groups[1].Value
      if ($n -notmatch '^(Steamworks Common|Proton |Steam Linux Runtime)') { Add-Game $n 'Steam' (Join-Path $l "steamapps\common\$d") }
    }
  }
}
# Epic Games
foreach ($f in Get-ChildItem -LiteralPath "$env:ProgramData\Epic\EpicGamesLauncher\Data\Manifests" -Filter '*.item' -ErrorAction SilentlyContinue) {
  try { $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json; if ($j.bIsApplication -ne $false) { Add-Game $j.DisplayName 'Epic Games' $j.InstallLocation } } catch {}
}
# GOG
foreach ($k in Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games' -ErrorAction SilentlyContinue) { $v = Get-ItemProperty -LiteralPath $k.PSPath; Add-Game $v.gameName 'GOG' $v.path }
# Ubisoft Connect
foreach ($k in Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs' -ErrorAction SilentlyContinue) { $v = Get-ItemProperty -LiteralPath $k.PSPath; $d = [string]$v.InstallDir; if ($d) { Add-Game (Split-Path $d.TrimEnd('/', '\') -Leaf) 'Ubisoft Connect' $d } }
# Riot
foreach ($f in Get-ChildItem -LiteralPath "$env:ProgramData\Riot Games\Metadata" -Recurse -Filter '*.product_settings.yaml' -ErrorAction SilentlyContinue) {
  $t = Get-Content -LiteralPath $f.FullName -Raw
  $d = [regex]::Match($t, 'product_install_full_path:\s*"?([^"\r\n]+)').Groups[1].Value
  if ($d) { Add-Game (Split-Path $d.TrimEnd('/', '\') -Leaf) 'Riot Games' $d }
}
# Amazon Games
$az = "$env:LOCALAPPDATA\Amazon Games\Data\Games\Sql\GameInstallInfo.sqlite"
# Programmes du registre qui trahissent leur plateforme par l'éditeur ou le dossier
$pub = @{ 'Electronic Arts' = 'EA App'; 'Blizzard Entertainment' = 'Battle.net'; 'Rockstar Games' = 'Rockstar Launcher'; 'Riot Games' = 'Riot Games'; 'Amazon' = 'Amazon Games' }
$seen = @{}; foreach ($g in $out) { $seen[$g.name.ToLower()] = $true }
foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall') {
  foreach ($k in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
    $v = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
    $n = [string]$v.DisplayName; $loc = [string]$v.InstallLocation
    if (-not $n -or $seen[$n.ToLower()]) { continue }
    $plat = ''
    if ($k.PSChildName -match '^Steam App') { $plat = 'Steam' }
    elseif ($loc -match '\\(EA Games|Origin Games)\\') { $plat = 'EA App' }
    elseif ($loc -match '\\Amazon Games\\Library\\') { $plat = 'Amazon Games' }
    elseif ($v.Publisher -and $pub[[string]$v.Publisher] -and $n -notmatch 'Battle\.net|EA app|Launcher|Riot Client|Amazon Games') { $plat = $pub[[string]$v.Publisher] }
    if ($plat) { Add-Game $n $plat $loc; $seen[$n.ToLower()] = $true }
  }
}
# Xbox / Game Pass : les jeux portent un MicrosoftGame.config
foreach ($p in Get-AppxPackage -PackageTypeFilter Main -ErrorAction SilentlyContinue) {
  if ($p.IsFramework -or $p.SignatureKind -eq 'System' -or -not $p.InstallLocation) { continue }
  if (Test-Path -LiteralPath (Join-Path $p.InstallLocation 'MicrosoftGame.config')) { Add-Game ($p.Name -replace '^[^.]+\.', '') 'Xbox / Microsoft Store' $p.InstallLocation }
}
Out-Json @{ items = $out; amazonDb = (Test-Path -LiteralPath $az) }
