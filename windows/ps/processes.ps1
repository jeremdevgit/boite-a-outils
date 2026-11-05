# Processus regroupés par nom : nombre, mémoire privée, processeur (mesuré
# sur 0,8 s), éditeur. Action « kill » : arrêt d'un processus non système.
if ($A.action -eq 'kill') {
  $deny = 'csrss', 'wininit', 'winlogon', 'lsass', 'smss', 'services', 'svchost', 'System', 'Registry', 'Idle', 'dwm', 'fontdrvhost', 'MsMpEng', 'SecurityHealthService', 'LsaIso', 'Memory Compression', 'sihost', 'ctfmon', 'audiodg', 'spoolsv', 'WUDFHost', 'conhost', 'BoiteAOutils'
  $name = [string]$A.name
  if ($deny -contains $name) { throw "Processus système protégé : l'arrêter ferait planter ou redémarrer Windows." }
  $procs = @(Get-Process -Name $name -ErrorAction Stop)
  $n = 0
  foreach ($p in $procs) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $n++ } catch {} }
  Out-Json @{ ok = $true; stopped = $n; total = $procs.Count }; return
}
$cores = [Environment]::ProcessorCount
$t0 = @{}
foreach ($p in Get-Process) { try { $t0[$p.Id] = $p.TotalProcessorTime.TotalMilliseconds } catch {} }
$sw = [Diagnostics.Stopwatch]::StartNew()
# mémoire privée réelle (« Mémoire » du Gestionnaire des tâches), compteurs bruts : rapides
$ws = @{}
foreach ($c in Get-CimInstance Win32_PerfRawData_PerfProc_Process -Property IDProcess, WorkingSetPrivate) { $ws[[int]$c.IDProcess] = [int64]$c.WorkingSetPrivate }
$left = 800 - $sw.ElapsedMilliseconds
if ($left -gt 0) { Start-Sleep -Milliseconds $left }
$elapsed = $sw.Elapsed.TotalMilliseconds
$groups = @{}
$vinfo = @{}
foreach ($p in Get-Process) {
  $cpu = 0.0
  try { if ($t0.ContainsKey($p.Id)) { $cpu = ($p.TotalProcessorTime.TotalMilliseconds - $t0[$p.Id]) / $elapsed / $cores * 100 } } catch {}
  $name = $p.ProcessName
  if (-not $groups.ContainsKey($name)) {
    $path = ''; $company = ''; $desc = ''
    try { $path = $p.Path } catch {}
    if ($path) {
      if (-not $vinfo.ContainsKey($path)) { try { $vinfo[$path] = [Diagnostics.FileVersionInfo]::GetVersionInfo($path) } catch { $vinfo[$path] = $null } }
      $vi = $vinfo[$path]; if ($vi) { $company = [string]$vi.CompanyName; $desc = [string]$vi.FileDescription }
    }
    $groups[$name] = [ordered]@{ name = $name; count = 0; ram = [int64]0; cpu = 0.0; path = $path; company = $company; description = $desc }
  }
  $g = $groups[$name]
  $g.count++
  $g.ram += $(if ($ws.ContainsKey($p.Id)) { $ws[$p.Id] } else { [int64]$p.PrivateMemorySize64 })
  $g.cpu += [math]::Max(0, $cpu)
}
$out = foreach ($g in $groups.Values) { $g.cpu = [math]::Round($g.cpu, 2); $g }
Out-Json @{ items = @($out); cores = $cores }
