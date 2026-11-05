# Points de restauration système : liste, activation de la protection du
# lecteur système, création (même si un point a déjà été créé dans les 24 h).
$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
function Points { @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ seq = $_.SequenceNumber; description = [string]$_.Description; date = ([Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime)).ToString('o') } }) }
function Enabled {
  # la protection est active si le lecteur système a un espace de clichés réservé
  $out = & "$env:SystemRoot\System32\vssadmin.exe" list shadowstorage /for=$env:SystemDrive 2>&1 | Out-String
  return ($out -match '\d+\s*(%|[KMGT]o|[KMGT]B)') -or ((Points).Count -gt 0)
}
if ($A.action -eq 'create') {
  if ($A.enable) { Enable-ComputerRestore -Drive "$env:SystemDrive\" }
  $prev = $null
  try { $prev = (Get-ItemProperty -LiteralPath $key -Name SystemRestorePointCreationFrequency -ErrorAction Stop).SystemRestorePointCreationFrequency } catch {}
  New-ItemProperty -LiteralPath $key -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force | Out-Null
  try {
    $before = (Points).Count
    Checkpoint-Computer -Description ([string]$A.description) -RestorePointType MODIFY_SETTINGS
    if ((Points).Count -le $before) { throw "Windows n'a pas créé le point (protection du système désactivée ?)" }
  } finally {
    if ($null -eq $prev) { Remove-ItemProperty -LiteralPath $key -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
    else { New-ItemProperty -LiteralPath $key -Name SystemRestorePointCreationFrequency -Value $prev -PropertyType DWord -Force | Out-Null }
  }
  Out-Json @{ ok = $true; points = Points }; return
}
$pts = Points
Out-Json @{ points = $pts; enabled = [bool](Enabled) }
