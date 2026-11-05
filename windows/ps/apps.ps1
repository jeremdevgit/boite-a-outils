# Applications du Microsoft Store et applications préinstallées : liste,
# lancement, réinitialisation, fermeture, désinstallation et réinstallation.
function Pkg([string]$full) {
  $p = Get-AppxPackage -PackageTypeFilter Main | Where-Object { $_.PackageFullName -eq $full } | Select-Object -First 1
  if (-not $p) { throw "Application introuvable" }
  $p
}
function Procs($p) {
  $loc = ([string]$p.InstallLocation).ToLower().TrimEnd('\') + '\'
  if ($loc.Length -lt 10) { return @() }
  @(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -and $_.Path.ToLower().StartsWith($loc) } catch { $false } })
}

switch ($A.action) {
  'launch' { $p = Pkg $A.full; Start-Process "shell:AppsFolder\$($p.PackageFamilyName)!$($A.app)"; Out-Json @{ ok = $true }; return }
  'stop' { $p = Pkg $A.full; $n = 0; foreach ($x in Procs $p) { try { Stop-Process -Id $x.Id -Force -ErrorAction Stop; $n++ } catch {} }; Out-Json @{ ok = $true; stopped = $n }; return }
  'reset' {
    $p = Pkg $A.full
    foreach ($x in Procs $p) { try { Stop-Process -Id $x.Id -Force } catch {} }
    Reset-AppxPackage -Package $p.PackageFullName
    Out-Json @{ ok = $true; detail = "$($A.title) : données de l'application effacées" }; return
  }
  'remove' {
    $done = @(); $failed = @()
    foreach ($full in @($A.items)) {
      try {
        $p = Pkg $full
        foreach ($x in Procs $p) { try { Stop-Process -Id $x.Id -Force } catch {} }
        Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
        $done += , @{ name = $p.Name; family = $p.PackageFamilyName }
      } catch { $failed += "$full : $($_.Exception.Message)" }
    }
    $r = @{ ok = $true; removed = $done.Count; failed = $failed; detail = (($done | ForEach-Object { $_.name }) -join ', ') }
    if ($done.Count) { $r.undo = @{ script = 'apps'; args = @{ action = 'restore'; items = $done } } }
    Out-Json $r; return
  }
  'restore' {
    # les fichiers restent dans WindowsApps tant que l'application est préinstallée
    # pour les nouveaux comptes ou installée pour un autre utilisateur
    $prov = @(); try { $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) } catch {}
    $missing = @()
    foreach ($i in @($A.items)) {
      $man = $null
      try { $o = Get-AppxPackage -AllUsers -Name $i.name -ErrorAction Stop | Select-Object -First 1; if ($o) { $man = Join-Path $o.InstallLocation 'AppxManifest.xml' } } catch {}
      if (-not $man -or -not (Test-Path -LiteralPath $man)) {
        $pp = $prov | Where-Object { $_.DisplayName -eq $i.name } | Select-Object -First 1
        if ($pp) { $man = [Environment]::ExpandEnvironmentVariables($pp.InstallLocation) }
      }
      if ($man -and (Test-Path -LiteralPath $man)) {
        try { Add-AppxPackage -Register $man -DisableDevelopmentMode -ErrorAction Stop; continue } catch {}
      }
      $missing += $i
    }
    if ($missing.Count) {
      foreach ($i in $missing) { Start-Process "ms-windows-store://pdp/?PFN=$($i.family)" }
      throw "Réinstallation à faire depuis le Microsoft Store (page ouverte) : $(($missing | ForEach-Object { $_.name }) -join ', ')"
    }
    Out-Json @{ ok = $true }; return
  }
}

# liste : nom affiché lu dans le manifeste (ressource traduite si possible)
Add-Type -Namespace Bao -Name Res -MemberDefinition '[DllImport("shlwapi.dll", CharSet=CharSet.Unicode)] public static extern int SHLoadIndirectString(string src, System.Text.StringBuilder outBuf, int cch, IntPtr r);' -ErrorAction SilentlyContinue
function Res($pkg, [string]$s) {
  if (-not $s.StartsWith('ms-resource:')) { return $s }
  $k = $s.Substring(12)
  $uris = if ($k.StartsWith('//')) { @("ms-resource:$k") } elseif ($k.StartsWith('/')) { @("ms-resource://$($pkg.Name)$k") } else { @("ms-resource://$($pkg.Name)/resources/$k", "ms-resource://$($pkg.Name)/$k") }
  foreach ($u in $uris) {
    $sb = New-Object System.Text.StringBuilder 512
    if ([Bao.Res]::SHLoadIndirectString("@{$($pkg.PackageFullName)?$u}", $sb, 512, [IntPtr]::Zero) -eq 0 -and $sb.Length) { return $sb.ToString() }
  }
  return ''
}
$running = @{}
foreach ($x in Get-Process -ErrorAction SilentlyContinue) { try { if ($x.Path -and $x.Path -match '\\WindowsApps\\([^\\]+)\\') { $running[$Matches[1].ToLower()] = $true } } catch {} }
$prov = @{}
if ($A.elevated) { try { foreach ($pp in Get-AppxProvisionedPackage -Online -ErrorAction Stop) { $prov[$pp.DisplayName] = $true } } catch {} }
$out = New-Object System.Collections.ArrayList
foreach ($p in Get-AppxPackage -PackageTypeFilter Main) {
  $title = ''; $app = ''; $pub = ''
  try {
    [xml]$m = Get-Content -LiteralPath (Join-Path $p.InstallLocation 'AppxManifest.xml') -Raw -ErrorAction Stop
    $title = Res $p ([string]$m.Package.Properties.DisplayName)
    $pub = Res $p ([string]$m.Package.Properties.PublisherDisplayName)
    $a = @($m.Package.Applications.Application)[0]
    if ($a) { $app = [string]$a.Id; if (-not $title -and $a.VisualElements) { $title = Res $p ([string]$a.VisualElements.DisplayName) } }
  } catch {}
  if (-not $title) { $title = $p.Name }
  [void]$out.Add([ordered]@{ name = $p.Name; full = $p.PackageFullName; family = $p.PackageFamilyName; title = $title; publisher = $pub; version = [string]$p.Version; location = [string]$p.InstallLocation; app = $app; system = ($p.SignatureKind -eq 'System'); nonRemovable = [bool]$p.NonRemovable; running = [bool]$running[$p.PackageFullName.ToLower()]; provisioned = [bool]$prov[$p.Name] })
}
Out-Json @{ items = $out }
