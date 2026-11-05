# Diagnostic poussé : lien PCIe réel, santé SMART, réseau, audio, batterie.
$K = 'DEVPKEY_PciDevice_'
$rate = @{ 1 = 2.5; 2 = 5; 3 = 8; 4 = 16; 5 = 32; 6 = 64 }
$pcie = New-Object System.Collections.ArrayList
foreach ($d in Get-PnpDevice -PresentOnly -InstanceId 'PCI\*' -ErrorAction SilentlyContinue) {
  # ponts et contrôleurs internes de la carte mère : nombreux, lents à lire et sans intérêt ici
  if ($d.Class -eq 'System') { continue }
  try { $p = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName "${K}CurrentLinkSpeed", "${K}CurrentLinkWidth", "${K}MaxLinkSpeed", "${K}MaxLinkWidth" -ErrorAction Stop } catch { continue }
  $v = @{}; foreach ($x in $p) { $v[$x.KeyName] = $x.Data }
  $cs = [int]$v["${K}CurrentLinkSpeed"]; $ms = [int]$v["${K}MaxLinkSpeed"]
  if (-not $cs -or -not $ms) { continue }
  [void]$pcie.Add([ordered]@{ name = [string]$d.FriendlyName; class = [string]$d.Class; speed = $rate[$cs]; width = [int]$v["${K}CurrentLinkWidth"]; maxSpeed = $rate[$ms]; maxWidth = [int]$v["${K}MaxLinkWidth"]; gen = $cs; maxGen = $ms })
}
$smart = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
    $c = $null; try { $c = $_ | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
    [ordered]@{ name = [string]$_.FriendlyName; media = [string]$_.MediaType; bus = [string]$_.BusType; size = [int64]$_.Size; health = [string]$_.HealthStatus; temp = [int]$c.Temperature; tempMax = [int]$c.TemperatureMax; wear = [int]$c.Wear; hours = [int64]$c.PowerOnHours; starts = [int64]$c.StartStopCycleCount; readErr = [int64]$c.ReadErrorsTotal; writeErr = [int64]$c.WriteErrorsTotal; latency = [int64]$c.ReadLatencyMax }
  })
$net = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Virtual -eq $false } | ForEach-Object {
    $ip = @(Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPAddress)
    [ordered]@{ name = [string]$_.Name; desc = [string]$_.InterfaceDescription; status = [string]$_.Status; speed = [string]$_.LinkSpeed; mac = [string]$_.MacAddress; driver = [string]$_.DriverVersion; driverDate = [string]$_.DriverDate; ip = ($ip -join ', ') }
  })
$audio = @(Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ name = [string]$_.Name; maker = [string]$_.Manufacturer; status = [string]$_.Status } })
$bat = $null
$b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
if ($b) {
  $st = Get-CimInstance -Namespace root\wmi BatteryStatus -ErrorAction SilentlyContinue | Select-Object -First 1
  $de = Get-CimInstance -Namespace root\wmi BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1
  $fu = Get-CimInstance -Namespace root\wmi BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1
  $bat = [ordered]@{ name = [string]$b.Name; percent = [int]$b.EstimatedChargeRemaining; design = [int64]$de.DesignedCapacity; full = [int64]$fu.FullChargedCapacity; chargeMw = [int64]$st.ChargeRate; dischargeMw = [int64]$st.DischargeRate; voltage = [int64]$st.Voltage; online = [bool]$st.PowerOnline }
}
Out-Json @{ pcie = $pcie; smart = $smart; net = $net; audio = $audio; battery = $bat }
