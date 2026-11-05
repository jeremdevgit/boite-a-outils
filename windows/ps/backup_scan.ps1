# Ce qui mérite une sauvegarde : dossiers personnels, AppData, sauvegardes de
# jeux, et tout dossier inhabituel du profil ou des autres disques.
$items = New-Object System.Collections.ArrayList
$seen = @{}
function Item($group, $label, $path, $why, $def, $note = '') {
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }
  $i = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  if (-not $i -or ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
  $k = $i.FullName.TrimEnd('\').ToLower()
  if ($seen[$k]) { return }
  $seen[$k] = $true
  [void]$items.Add([ordered]@{ group = $group; label = $label; path = $i.FullName; why = $why; def = [bool]$def; note = $note })
}
$home_ = $env:USERPROFILE
$kf = { param($n) [Environment]::GetFolderPath($n) }
$cloud = '(?i)\\(OneDrive|Nextcloud|Dropbox|Google Drive|iCloudDrive|MEGA)'
foreach ($f in @(@('Documents', 'MyDocuments', 'Vos fichiers, et souvent les réglages de jeux (My Games, Rockstar Games…)'), @('Bureau', 'Desktop', 'Fichiers posés sur le bureau'), @('Images', 'MyPictures', 'Photos et captures'), @('Vidéos', 'MyVideos', 'Vidéos et enregistrements'), @('Musique', 'MyMusic', 'Musique'))) {
  $p = & $kf $f[1]
  $c = $p -match $cloud
  Item 'Dossiers personnels' $f[0] $p $f[2] (-not $c) $(if ($c) { 'Déjà synchronisé dans le cloud' } else { '' })
}
Item 'Dossiers personnels' 'Téléchargements' (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path 'Souvent beaucoup d''installateurs déjà inutiles : à vous de voir' $false
Item 'Jeux' 'Parties sauvegardées' "$home_\Saved Games" 'Sauvegardes et réglages de nombreux jeux' $true
$steam = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath
if ($steam) { Item 'Jeux' 'Steam : données utilisateur' "$steam\userdata" 'Réglages et sauvegardes locales des jeux Steam (hors Steam Cloud), configuration de la manette' $true }
Item 'Jeux' 'Ubisoft : sauvegardes' "${env:ProgramFiles(x86)}\Ubisoft\Ubisoft Game Launcher\savegames" 'Sauvegardes locales Ubisoft Connect' $true
Item 'Paramètres des logiciels' 'AppData\Roaming' $env:APPDATA 'Réglages de la plupart des logiciels et de nombreux jeux' $true 'Fermez vos navigateurs et Discord : un fichier ouvert ne peut pas être copié'
Item 'Paramètres des logiciels' 'AppData\Local' $env:LOCALAPPDATA 'Réglages et sauvegardes de jeux (Unreal notamment), profils de navigateurs. Souvent volumineux' $false 'Caches ignorés. Les mots de passe des navigateurs ne se déchiffrent que sur ce compte Windows : exportez-les depuis le navigateur'
Item 'Paramètres des logiciels' 'AppData\LocalLow' "$home_\AppData\LocalLow" 'Sauvegardes de nombreux jeux Unity' $true
Item 'Paramètres des logiciels' 'Polices personnelles' "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" 'Polices installées pour votre compte' $true
Item 'Paramètres des logiciels' 'Fichier hosts' "$env:SystemRoot\System32\drivers\etc\hosts" 'Redirections réseau personnalisées' $false
Item 'Clés et développement' 'Clés SSH' "$home_\.ssh" 'Clés privées : gardez la sauvegarde en lieu sûr' $true 'Contenu sensible'
Item 'Clés et développement' 'Git' "$home_\.gitconfig" 'Configuration de Git' $true
Item 'Clés et développement' 'Configuration' "$home_\.config" 'Configuration d''outils en ligne de commande' $true
# ce qu'on aurait oublié : autres dossiers du profil et des autres disques
$std = 'AppData|Application Data|Contacts|Cookies|Desktop|Documents|Downloads|Favorites|Links|Local Settings|Menu Démarrer|Mes documents|Modèles|Music|Pictures|Recent|Saved Games|Searches|SendTo|Videos|Voisinage.*|Start Menu|Templates|My Documents|NetHood|PrintHood'
$bulky = '^\.(cache|cargo|rustup|gradle|nuget|npm|android|vscode|local)$'
foreach ($d in Get-ChildItem -LiteralPath $home_ -Directory -Force -ErrorAction SilentlyContinue) {
  if ($d.Name -match "^($std)$" -or $d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
  if ($d.FullName -match $cloud) { Item 'Autres dossiers trouvés' $d.Name $d.FullName 'Dossier synchronisé dans le cloud' $false 'Déjà synchronisé dans le cloud'; continue }
  $b = $d.Name -match $bulky
  Item 'Autres dossiers trouvés' $d.Name $d.FullName $(if ($b) { 'Outils retéléchargeables' } else { 'Dossier de votre profil, hors emplacements habituels' }) (-not $b)
}
Get-ChildItem -LiteralPath $home_ -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\.[a-z]' -and $_.Name -ne '.gitconfig' -and $_.Length -lt 5MB } | ForEach-Object { Item 'Autres dossiers trouvés' $_.Name $_.FullName 'Fichier de configuration' $true }
$skipRoot = '(?i)^(Windows|Program Files.*|ProgramData|Users|PerfLogs|Recovery|System Volume Information|\$.*|MSOCache|Intel|AMD|NVIDIA|SteamLibrary|Steam|Epic Games|Games|XboxGames|EA Games|GOG Games|Riot Games|WindowsApps|WpSystem|Config\.Msi|OneDriveTemp|Boot|Drivers)$'
foreach ($v in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') {
  foreach ($d in Get-ChildItem -LiteralPath "$($v.DeviceID)\" -Directory -ErrorAction SilentlyContinue) {
    if ($d.Name -notmatch $skipRoot) { Item "Autres disques ($($v.DeviceID))" $d.Name $d.FullName 'Dossier à la racine du disque' $false }
  }
}
$hasWifi = $false; try { $hasWifi = [bool](Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.PhysicalMediaType -match '802\.11' }) } catch {}
Out-Json @{ items = $items; hasWifi = $hasWifi }
