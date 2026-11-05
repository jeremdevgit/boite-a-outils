# Modes d'alimentation : liste, choix du mode actif, ajout du mode
# « Performances ultimes » (masqué par défaut sur les PC de bureau).
$pc = "$env:SystemRoot\System32\powercfg.exe"
function Plans {
  # noms traduits lus par WMI (la sortie de powercfg dépend de la page de code de la console)
  @(Get-CimInstance -Namespace root\cimv2\power -ClassName Win32_PowerPlan | ForEach-Object {
      [ordered]@{ guid = ([string]$_.InstanceID -replace '^.*\{|\}$', ''); name = [string]$_.ElementName; active = [bool]$_.IsActive }
    })
}
function Active { (Plans | Where-Object { $_.active } | Select-Object -First 1).guid }
switch ($A.action) {
  'set' {
    $prev = Active
    & $pc /setactive $A.guid | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Mode d'alimentation introuvable" }
    Out-Json @{ ok = $true; detail = "$prev → $($A.guid)"; undo = @{ script = 'power'; args = @{ action = 'set'; guid = $prev } } }; return
  }
  'ultimate' {
    $prev = Active
    $o = (& $pc -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61) -join ' '
    $m = [regex]::Match($o, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
    if (-not $m.Success) { throw "Ce mode n'est pas disponible sur cette édition de Windows" }
    & $pc /setactive $m.Value | Out-Null
    Out-Json @{ ok = $true; detail = "Mode Performances ultimes ajouté ($($m.Value))"; undo = @{ script = 'power'; args = @{ action = 'drop'; guid = $m.Value; back = $prev } } }; return
  }
  'drop' {
    if ($A.back) { & $pc /setactive $A.back | Out-Null }
    & $pc /delete $A.guid | Out-Null
    Out-Json @{ ok = $true }; return
  }
}
Out-Json @{ plans = @(Plans) }
