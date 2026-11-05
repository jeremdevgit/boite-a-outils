# Volumes, type de disque (SSD/HDD), santé SMART et optimisation planifiée.
$phys = @{}
foreach ($pd in Get-PhysicalDisk) {
  $rel = $null
  try { $rel = $pd | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
  $phys[[string]$pd.DeviceId] = [ordered]@{
    name = [string]$pd.FriendlyName; media = [string]$pd.MediaType; bus = [string]$pd.BusType; health = [string]$pd.HealthStatus; size = [int64]$pd.Size
    temperature = $(if ($rel) { $rel.Temperature } else { $null }); wear = $(if ($rel) { $rel.Wear } else { $null })
    readErrors = $(if ($rel) { $rel.ReadErrorsTotal } else { $null }); writeErrors = $(if ($rel) { $rel.WriteErrorsTotal } else { $null }); hours = $(if ($rel) { $rel.PowerOnHours } else { $null })
  }
}
$vols = @()
foreach ($v in Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' }) {
  $disk = $null
  try { $part = Get-Partition -DriveLetter $v.DriveLetter -ErrorAction Stop; $disk = $phys[[string]$part.DiskNumber] } catch {}
  $vols += , [ordered]@{ letter = [string]$v.DriveLetter; label = [string]$v.FileSystemLabel; fs = [string]$v.FileSystem; size = [int64]$v.Size; free = [int64]$v.SizeRemaining; health = [string]$v.HealthStatus; disk = $disk }
}
$task = $null
try { $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop; $i = $t | Get-ScheduledTaskInfo; $task = @{ state = [string]$t.State; last = $(if ($i.LastRunTime -and $i.LastRunTime.Year -gt 2000) { $i.LastRunTime.ToString('o') } else { $null }) } } catch {}
Out-Json @{ volumes = $vols; disks = @($phys.Values); optimizeTask = $task }
