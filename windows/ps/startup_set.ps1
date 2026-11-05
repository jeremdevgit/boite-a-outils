# Active ou désactive un programme au démarrage, comme le Gestionnaire des
# tâches (valeur StartupApproved, rien n'est supprimé), ou retire une entrée
# cassée après sauvegarde. Chaque action renvoie de quoi l'annuler.
$base = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$backup = Join-Path $env:BAO_DATA 'sauvegardes'

switch ($A.kind) {
  'raw' {
    # annulation : valeur StartupApproved d'avant
    if ($A.prev) { Set-ItemProperty -LiteralPath $A.key -Name $A.name -Value ([Convert]::FromBase64String($A.prev)) -Type Binary }
    else { Remove-ItemProperty -LiteralPath $A.key -Name $A.name -ErrorAction SilentlyContinue }
    Out-Json @{ ok = $true }; return
  }
  'restoreValue' {
    if (-not (Test-Path -LiteralPath $A.key)) { New-Item -Path $A.key -Force | Out-Null }
    New-ItemProperty -LiteralPath $A.key -Name $A.name -Value $A.value -PropertyType $A.type -Force | Out-Null
    Out-Json @{ ok = $true }; return
  }
  'restoreFile' { Move-Item -LiteralPath $A.from -Destination $A.to -Force; Out-Json @{ ok = $true }; return }
  'restoreTask' {
    Register-ScheduledTask -Xml (Get-Content -LiteralPath $A.xml -Raw) -TaskPath $A.taskPath -TaskName $A.name -Force | Out-Null
    Out-Json @{ ok = $true }; return
  }
  'task' {
    $t = Get-ScheduledTask -TaskPath $A.taskPath -TaskName $A.name
    if ($A.action -eq 'delete') {
      New-Item -ItemType Directory -Force -Path $backup | Out-Null
      $xml = Join-Path $backup ("tache-" + ($A.name -replace '[^\w.-]', '_') + "-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".xml")
      Export-ScheduledTask -TaskPath $A.taskPath -TaskName $A.name | Set-Content -LiteralPath $xml -Encoding Unicode
      Unregister-ScheduledTask -TaskPath $A.taskPath -TaskName $A.name -Confirm:$false
      Out-Json @{ ok = $true; detail = "Tâche supprimée (sauvegarde : $xml)"; undo = @{ script = 'startup_set'; args = @{ kind = 'restoreTask'; taskPath = $A.taskPath; name = $A.name; xml = $xml } } }
      return
    }
    $was = ($t.State -ne 'Disabled')
    if ($A.enable) { Enable-ScheduledTask -TaskPath $A.taskPath -TaskName $A.name | Out-Null } else { Disable-ScheduledTask -TaskPath $A.taskPath -TaskName $A.name | Out-Null }
    Out-Json @{ ok = $true; detail = "Tâche $($A.taskPath)$($A.name)"; undo = @{ script = 'startup_set'; args = @{ kind = 'task'; taskPath = $A.taskPath; name = $A.name; enable = $was } } }
    return
  }
}

if ($A.kind -eq 'run') { $sub = $A.ap; $name = $A.name; $hive = $A.hive }
elseif ($A.kind -eq 'folder') { $sub = 'StartupFolder'; $name = [IO.Path]::GetFileName($A.path); $hive = $A.hive }
else { throw "type inconnu : $($A.kind)" }

if ($A.action -eq 'delete') {
  if ($A.kind -eq 'run') {
    $key = "$($hive):\$($A.key)"
    $k = Get-Item -LiteralPath $key
    $val = $k.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $type = $k.GetValueKind($name).ToString()
    Remove-ItemProperty -LiteralPath $key -Name $name
    Out-Json @{ ok = $true; detail = "$key\$name = $val"; undo = @{ script = 'startup_set'; args = @{ kind = 'restoreValue'; key = $key; name = $name; value = $val; type = $type } } }
  } else {
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    $dest = Join-Path $backup ((Get-Date -Format 'yyyyMMdd-HHmmss-') + $name)
    Move-Item -LiteralPath $A.path -Destination $dest
    Out-Json @{ ok = $true; detail = "Raccourci déplacé vers $dest"; undo = @{ script = 'startup_set'; args = @{ kind = 'restoreFile'; from = $dest; to = $A.path } } }
  }
  return
}

$k = "$($hive):\$base\$sub"
if (-not (Test-Path -LiteralPath $k)) { New-Item -Path $k -Force | Out-Null }
$prev = $null
try { $prev = (Get-ItemProperty -LiteralPath $k -Name $name -ErrorAction Stop).$name } catch {}
$bytes = [byte[]](@($(if ($A.enable) { 2 } else { 3 })) + (, 0 * 11))
Set-ItemProperty -LiteralPath $k -Name $name -Value $bytes -Type Binary
$prevB64 = if ($prev -is [byte[]]) { [Convert]::ToBase64String($prev) } else { $null }
Out-Json @{ ok = $true; detail = $name; undo = @{ script = 'startup_set'; args = @{ kind = 'raw'; key = $k; name = $name; prev = $prevB64 } } }
