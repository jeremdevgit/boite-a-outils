# Fonctionnalités facultatives de Windows (WSL, Hyper-V, Bac à sable, .NET 3.5…) :
# liste, activation et désactivation. L'inverse sert d'annulation.
if ($A.action -eq 'set') {
  $f = Get-WindowsOptionalFeature -Online -FeatureName $A.name
  if (-not $f) { throw "Fonctionnalité introuvable : $($A.name)" }
  $was = $f.State -eq 'Enabled'
  $r = if ($A.on) { Enable-WindowsOptionalFeature -Online -FeatureName $A.name -All -NoRestart -WarningAction SilentlyContinue }
  else { Disable-WindowsOptionalFeature -Online -FeatureName $A.name -NoRestart -WarningAction SilentlyContinue }
  Out-Json @{ ok = $true; restart = [bool]$r.RestartNeeded; detail = "$($A.name) : $(if ($A.on) { 'activée' } else { 'désactivée' })"; undo = @{ script = 'features'; args = @{ action = 'set'; name = $A.name; on = $was } } }
  return
}
$out = New-Object System.Collections.ArrayList
foreach ($f in Get-WindowsOptionalFeature -Online) {
  [void]$out.Add([ordered]@{ name = $f.FeatureName; state = [string]$f.State })
}
Out-Json @{ items = $out }
