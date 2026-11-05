# Lecture et écriture de valeurs du registre pour les optimisations.
# « set » renvoie les valeurs d'avant pour pouvoir les remettre ; une valeur
# absente avant est supprimée à l'annulation.
function Cur($p, $n) {
  try {
    $k = Get-Item -LiteralPath $p -ErrorAction Stop
    $v = $k.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($null -eq $v -and -not ($k.GetValueNames() -contains $n)) { return @{ exists = $false } }
    return @{ exists = $true; value = $v; type = $k.GetValueKind($n).ToString() }
  } catch { return @{ exists = $false } }
}
if ($A.action -eq 'get') {
  $out = @()
  foreach ($i in $A.items) { $c = Cur $i.path $i.name; $out += , @{ path = $i.path; name = $i.name; exists = $c.exists; value = $c.value } }
  Out-Json @{ values = $out }; return
}
if ($A.action -eq 'set') {
  $prev = @()
  foreach ($i in $A.items) {
    $c = Cur $i.path $i.name
    $prev += , @{ path = $i.path; name = $i.name; type = $(if ($c.exists) { $c.type } else { $i.type }); value = $(if ($c.exists) { $c.value } else { $null }); dropKey = $i.dropKey }
    $n = if ($i.name -eq '') { '(default)' } else { $i.name } # nom vide : valeur par défaut de la clé
    if ($null -eq $i.value) {
      if ($c.exists) {
        # Remove-ItemProperty ne sait pas retirer la valeur par défaut d'une clé
        $root = @{ HKCU = [Microsoft.Win32.Registry]::CurrentUser; HKLM = [Microsoft.Win32.Registry]::LocalMachine }[$i.path.Substring(0, 4)]
        $k = $root.OpenSubKey($i.path.Substring(6), $true)
        try { $k.DeleteValue([string]$i.name) } finally { $k.Close() }
      }
      # dropKey : les clés devenues vides sont retirées, de la clé de la valeur jusqu'à celle-ci
      if ($i.dropKey -and $i.path.StartsWith($i.dropKey)) {
        $k = $i.path
        while ($k.Length -ge $i.dropKey.Length -and (Test-Path -LiteralPath $k)) {
          $it = Get-Item -LiteralPath $k
          if ($it.ValueCount -or $it.SubKeyCount) { break }
          Remove-Item -LiteralPath $k -Force
          $k = Split-Path $k -Parent
        }
      }
    } else {
      if (-not (Test-Path -LiteralPath $i.path)) { New-Item -Path $i.path -Force | Out-Null }
      $val = if ($i.type -eq 'Binary') { [byte[]]@($i.value) } elseif ($i.type -eq 'MultiString') { [string[]]$i.value } else { $i.value }
      New-ItemProperty -LiteralPath $i.path -Name $n -Value $val -PropertyType $i.type -Force | Out-Null
    }
  }
  Out-Json @{ ok = $true; detail = (($A.items | ForEach-Object { "$($_.path)\$($_.name)" }) -join ' · '); undo = @{ script = 'reg'; args = @{ action = 'set'; items = $prev } } }
  return
}
throw "action inconnue"
