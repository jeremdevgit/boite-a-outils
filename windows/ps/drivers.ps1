# Pilotes : installés (avec leur âge), proposés par Windows Update, installation
# de ceux que l'utilisateur coche.
function Wu { $s = New-Object -ComObject Microsoft.Update.Session; $s.ClientApplicationID = 'Boite a outils'; $s }
if ($A.action -eq 'search') {
  $r = (Wu).CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
  $list = @(foreach ($u in $r.Updates) {
      [ordered]@{ id = [string]$u.Identity.UpdateID; title = [string]$u.Title; maker = [string]$u.DriverManufacturer; model = [string]$u.DriverModel; class = [string]$u.DriverClass; hwid = [string]$u.DriverHardwareID; date = $(if ($u.DriverVerDate) { ([datetime]$u.DriverVerDate).ToString('o') } else { '' }); size = [int64]$u.MaxDownloadSize }
    })
  Out-Json @{ items = $list }; return
}
if ($A.action -eq 'install') {
  $s = Wu
  $want = @($A.ids)
  $r = $s.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
  $col = New-Object -ComObject Microsoft.Update.UpdateColl
  foreach ($u in $r.Updates) { if ($want -contains [string]$u.Identity.UpdateID) { if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$col.Add($u) } }
  if (-not $col.Count) { throw 'Ces pilotes ne sont plus proposés par Windows Update' }
  $d = $s.CreateUpdateDownloader(); $d.Updates = $col; [void]$d.Download()
  $i = $s.CreateUpdateInstaller(); $i.Updates = $col; $res = $i.Install()
  $per = @(for ($k = 0; $k -lt $col.Count; $k++) { [ordered]@{ title = [string]$col.Item($k).Title; code = [int]$res.GetUpdateResult($k).ResultCode } })
  Out-Json @{ ok = ($res.ResultCode -eq 2); code = [int]$res.ResultCode; reboot = [bool]$res.RebootRequired; items = $per; detail = (($per | ForEach-Object { $_.title }) -join ', ') }; return
}
$bad = @{}
foreach ($d in Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode<>0' -ErrorAction SilentlyContinue) { $bad[[string]$d.PNPDeviceID] = [int]$d.ConfigManagerErrorCode }
$items = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -and $_.InfName } | ForEach-Object {
    [ordered]@{ name = [string]$_.DeviceName; class = [string]$_.DeviceClass; provider = [string]$_.DriverProviderName; maker = [string]$_.Manufacturer; version = [string]$_.DriverVersion; date = $(if ($_.DriverDate) { $_.DriverDate.ToString('o') } else { '' }); inf = [string]$_.InfName; hwid = [string]$_.HardWareID; device = [string]$_.DeviceID; signed = [bool]$_.IsSigned; error = [int]$bad[[string]$_.DeviceID] }
  })
$missing = @(foreach ($k in $bad.Keys) { if (-not ($items | Where-Object { $_.device -eq $k })) { $e = Get-CimInstance Win32_PnPEntity -Filter "PNPDeviceID='$($k -replace '\\', '\\')'" -ErrorAction SilentlyContinue; [ordered]@{ name = [string]$e.Name; device = $k; error = $bad[$k]; hwid = [string](@($e.HardwareID)[0]); hwids = @($e.HardwareID | Select-Object -First 3) } } })
$b = Get-CimInstance Win32_BaseBoard
Out-Json @{ items = $items; missing = $missing; board = @{ maker = [string]$b.Manufacturer; model = [string]$b.Product } }
