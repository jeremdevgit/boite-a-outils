# Entretien : Windows Update, cache des icônes et du Store, Explorateur,
# historique, Mode Dieu, images Windows à la une, rapport de batterie.
function Restart-Shell {
  Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
  # Windows relance l'Explorateur de lui-même (AutoRestartShell) ; sinon, lancé sans droits administrateur
  for ($i = 0; $i -lt 20 -and -not (Get-Process explorer -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
  if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { & "$env:SystemRoot\System32\runas.exe" /trustlevel:0x20000 "$env:SystemRoot\explorer.exe" | Out-Null }
}
switch ($A.action) {
  'explorer' { Restart-Shell; Out-Json @{ ok = $true }; return }
  'iconcache' {
    & "$env:SystemRoot\System32\ie4uinit.exe" -show 2>&1 | Out-Null
    Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    $n = 0
    foreach ($f in @(Get-Item -LiteralPath "$env:LOCALAPPDATA\IconCache.db" -Force -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Filter 'iconcache_*.db' -Force -ErrorAction SilentlyContinue)) {
      try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $n++ } catch {}
    }
    Restart-Shell
    Out-Json @{ ok = $true; removed = $n }; return
  }
  'wureset' {
    # composants de Windows Update remis à zéro : les dossiers sont renommés, pas supprimés
    $svcs = 'wuauserv', 'bits', 'cryptsvc', 'msiserver', 'usosvc'
    foreach ($s in $svcs) { try { Stop-Service -Name $s -Force -ErrorAction Stop } catch {} }
    $done = @()
    foreach ($d in "$env:SystemRoot\SoftwareDistribution", "$env:SystemRoot\System32\catroot2") {
      if (-not (Test-Path -LiteralPath $d)) { continue }
      $bak = "$d.bak"
      if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Recurse -Force -ErrorAction SilentlyContinue }
      try { Rename-Item -LiteralPath $d -NewName (Split-Path $bak -Leaf) -ErrorAction Stop; $done += $d } catch {}
    }
    foreach ($s in 'cryptsvc', 'bits', 'wuauserv') { try { Start-Service -Name $s -ErrorAction Stop } catch {} }
    Out-Json @{ ok = $true; renamed = $done; detail = "Dossiers renommés en .bak : $($done -join ', ')" }; return
  }
  'storecache' { Start-Process "$env:SystemRoot\System32\wsreset.exe"; Out-Json @{ ok = $true }; return }
  'history' {
    $n = 0
    foreach ($d in "$env:APPDATA\Microsoft\Windows\Recent", "$env:APPDATA\Microsoft\Windows\Recent\AutomaticDestinations", "$env:APPDATA\Microsoft\Windows\Recent\CustomDestinations") {
      foreach ($f in Get-ChildItem -LiteralPath $d -File -Force -ErrorAction SilentlyContinue) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $n++ } catch {} }
    }
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
    foreach ($k in 'RunMRU', 'TypedPaths', 'RecentDocs', 'WordWheelQuery') { Remove-Item -LiteralPath "$adv\$k" -Recurse -Force -ErrorAction SilentlyContinue }
    Out-Json @{ ok = $true; removed = $n }; return
  }
  'godmode' {
    $p = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Mode Dieu.{ED7BA470-8E54-465E-825C-99712043E01C}'
    if ($A.remove) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; Out-Json @{ ok = $true }; return }
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    Out-Json @{ ok = $true; detail = $p; undo = @{ script = 'repair'; args = @{ action = 'godmode'; remove = $true } } }; return
  }
  'spotlight' {
    # images « Windows à la une » de l'écran de verrouillage et du bureau, copiées en .jpg
    Add-Type -AssemblyName System.Drawing
    $dest = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Windows à la une'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $src = @(Get-ChildItem -LiteralPath "$env:LOCALAPPDATA\Packages\Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy\LocalState\Assets" -File -ErrorAction SilentlyContinue) +
      @(Get-ChildItem -LiteralPath "$env:LOCALAPPDATA\Packages\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\LocalCache\Microsoft\IrisService" -Recurse -File -Include *.jpg, *.jpeg, *.png -ErrorAction SilentlyContinue)
    $n = 0
    foreach ($f in $src) {
      if ($f.Length -lt 100KB) { continue }
      try {
        $img = [Drawing.Image]::FromFile($f.FullName); $wide = $img.Width -ge 1280 -and $img.Width -gt $img.Height; $img.Dispose()
        if (-not $wide) { continue }
        $t = Join-Path $dest ($f.BaseName.Substring(0, [Math]::Min(24, $f.BaseName.Length)) + '.jpg')
        if (-not (Test-Path -LiteralPath $t)) { Copy-Item -LiteralPath $f.FullName -Destination $t; $n++ }
      } catch {}
    }
    Out-Json @{ ok = $true; copied = $n; folder = $dest }; return
  }
  'battery' {
    if (-not (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)) { throw "Aucune batterie détectée : ce rapport ne concerne que les PC portables." }
    $f = Join-Path $env:BAO_DATA 'rapport-batterie.html'
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    & "$env:SystemRoot\System32\powercfg.exe" /batteryreport /output "$f" 2>&1 | Out-Null
    if (-not (Test-Path -LiteralPath $f)) { throw "Aucune batterie détectée sur ce PC" }
    Out-Json @{ ok = $true; path = $f }; return
  }
  'svc' {
    # état de quelques services (réglages de la page Performances)
    $out = @{}
    foreach ($n in @($A.names)) {
      $s = Get-CimInstance Win32_Service -Filter "Name='$($n -replace "'", "''")'" -ErrorAction SilentlyContinue
      if ($s) { $out[$n] = @{ start = $(if ($s.StartMode -eq 'Auto' -and $s.DelayedAutoStart) { 'delayed-auto' } else { @{ Auto = 'auto'; Manual = 'demand'; Disabled = 'disabled' }[[string]$s.StartMode] }); state = [string]$s.State } }
    }
    Out-Json @{ services = $out }; return
  }
  'status' {
    # activation de Windows, Mode Dieu présent, mise en pause des mises à jour
    $lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" -ErrorAction SilentlyContinue | Select-Object -First 1
    $god = Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Mode Dieu.{ED7BA470-8E54-465E-825C-99712043E01C}')
    $battery = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    Out-Json @{ activated = $(if ($lic) { $lic.LicenseStatus -eq 1 } else { $null }); godmode = $god; battery = $battery }; return
  }
}
throw "action inconnue"
