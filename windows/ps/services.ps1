# Services : type de démarrage, état, éditeur, et relance automatique en cas
# d'arrêt (actions de récupération « Redémarrer le service »).
$root = 'HKLM:\SYSTEM\CurrentControlSet\Services'
$win = $env:SystemRoot.ToLower()
$list = New-Object System.Collections.ArrayList
$companies = @{}
foreach ($s in Get-CimInstance Win32_Service) {
  $path = [string]$s.PathName
  $exe = ''
  if ($path.StartsWith('"')) { $e = $path.IndexOf('"', 1); if ($e -gt 0) { $exe = $path.Substring(1, $e - 1) } }
  else { $m = [regex]::Match($path, '^(.+?\.exe)', 'IgnoreCase'); $exe = if ($m.Success) { $m.Groups[1].Value } else { $path } }
  $exe = [Environment]::ExpandEnvironmentVariables($exe) -replace '^\\\\\?\\', ''
  $inWin = $exe.ToLower().StartsWith($win)
  $company = ''
  if (-not $inWin -and $exe) {
    if ($companies.ContainsKey($exe)) { $company = $companies[$exe] }
    elseif (Test-Path -LiteralPath $exe -PathType Leaf) { try { $company = [string](Get-Item -LiteralPath $exe).VersionInfo.CompanyName } catch {}; $companies[$exe] = $company }
  }
  $restart = $false
  try {
    $b = (Get-ItemProperty -LiteralPath "$root\$($s.Name)" -Name FailureActions -ErrorAction Stop).FailureActions
    if ($b.Length -ge 20) {
      $n = [BitConverter]::ToInt32($b, 12)
      for ($i = 0; $i -lt $n -and (24 + $i * 8) -le $b.Length; $i++) { if ([BitConverter]::ToInt32($b, 20 + $i * 8) -eq 1) { $restart = $true } }
    }
  } catch {}
  [void]$list.Add([ordered]@{ name = $s.Name; display = [string]$s.DisplayName; description = [string]$s.Description; start = [string]$s.StartMode; delayed = [bool]$s.DelayedAutoStart; state = [string]$s.State; exe = $exe; company = $company; microsoft = ($inWin -or $company -match 'Microsoft'); account = [string]$s.StartName; restart = $restart; pid = [int]$s.ProcessId })
}
Out-Json @{ items = $list }
