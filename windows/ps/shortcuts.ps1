# Raccourcis cassés : Bureau, menu Démarrer, barre des tâches épinglée.
# Les raccourcis sans cible lisible (installateurs MSI, applis du Store) et
# les cibles réseau (lecteur peut-être simplement déconnecté) sont ignorés.
$sh = New-Object -ComObject WScript.Shell
$dirs = @(
  @{ p = [Environment]::GetFolderPath('Desktop'); l = 'Bureau' },
  @{ p = [Environment]::GetFolderPath('CommonDesktopDirectory'); l = 'Bureau public' },
  @{ p = [Environment]::GetFolderPath('Programs'); l = 'Menu Démarrer' },
  @{ p = [Environment]::GetFolderPath('CommonPrograms'); l = 'Menu Démarrer (tous)' },
  @{ p = (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'); l = 'Barre des tâches' }
)
$items = New-Object System.Collections.ArrayList
foreach ($d in $dirs) {
  if (-not $d.p -or -not (Test-Path -LiteralPath $d.p)) { continue }
  foreach ($f in Get-ChildItem -LiteralPath $d.p -Filter *.lnk -Recurse -Force -ErrorAction SilentlyContinue) {
    try { $t = $sh.CreateShortcut($f.FullName).TargetPath } catch { continue }
    if (-not $t -or $t.StartsWith('\\') -or $t -notmatch '^[A-Za-z]:\\') { continue }
    if (-not (Test-Path -LiteralPath $t)) { [void]$items.Add([ordered]@{ path = $f.FullName; target = $t; location = $d.l }) }
  }
}
Out-Json @{ items = $items }
