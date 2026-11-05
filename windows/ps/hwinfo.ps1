# Fiche matériel (façon CPU-Z) : carte mère, BIOS, barrettes de mémoire,
# cartes graphiques, système. Le processeur est lu en natif (CPUID).
$cs = Get-CimInstance Win32_ComputerSystem
$bb = Get-CimInstance Win32_BaseBoard
$bios = Get-CimInstance Win32_BIOS
$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$types = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }
$forms = @{ 8 = 'DIMM'; 12 = 'SO-DIMM' }
$mods = @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
    [ordered]@{
      slot = [string]$_.DeviceLocator; bank = [string]$_.BankLabel; size = [int64]$_.Capacity
      type = $(if ($types[[int]$_.SMBIOSMemoryType]) { $types[[int]$_.SMBIOSMemoryType] } else { '' })
      form = $(if ($forms[[int]$_.FormFactor]) { $forms[[int]$_.FormFactor] } else { '' })
      speed = [int]$_.Speed; configured = [int]$_.ConfiguredClockSpeed
      maker = ([string]$_.Manufacturer).Trim(); part = ([string]$_.PartNumber).Trim(); serial = ([string]$_.SerialNumber).Trim()
      voltage = [int]$_.ConfiguredVoltage
    }
  })
$slots = (Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object -Property MemoryDevices -Sum).Sum
# mémoire vidéo réelle (la valeur WMI est limitée à 4 Go)
$vram = @{}
foreach ($k in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue) {
  $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
  if ($p.DriverDesc -and $p.'HardwareInformation.qwMemorySize') { $vram[[string]$p.DriverDesc] = [int64]$p.'HardwareInformation.qwMemorySize' }
}
$gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Virtual|Remote|Parsec' } | ForEach-Object {
    [ordered]@{
      name = [string]$_.Name; maker = [string]$_.AdapterCompatibility; driver = [string]$_.DriverVersion
      date = $(if ($_.DriverDate) { $_.DriverDate.ToString('o') } else { '' })
      vram = $(if ($vram[[string]$_.Name]) { $vram[[string]$_.Name] } else { [int64]$_.AdapterRAM })
      mode = $(if ($_.CurrentHorizontalResolution) { "$($_.CurrentHorizontalResolution) × $($_.CurrentVerticalResolution) à $($_.CurrentRefreshRate) Hz" } else { '' })
      pnp = [string]$_.PNPDeviceID
    }
  })
$disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
    [ordered]@{ name = [string]$_.FriendlyName; media = [string]$_.MediaType; bus = [string]$_.BusType; size = [int64]$_.Size; health = [string]$_.HealthStatus; firmware = [string]$_.FirmwareVersion }
  })
$monitors = @(Get-CimInstance -Namespace root\wmi WmiMonitorID -ErrorAction SilentlyContinue | ForEach-Object {
    $n = -join ($_.UserFriendlyName | Where-Object { $_ } | ForEach-Object { [char]$_ })
    $m = -join ($_.ManufacturerName | Where-Object { $_ } | ForEach-Object { [char]$_ })
    [ordered]@{ name = $n; maker = $m; year = [int]$_.YearOfManufacture }
  })
$tpm = $null; try { $t = Get-Tpm -ErrorAction Stop; $tpm = @{ present = [bool]$t.TpmPresent; ready = [bool]$t.TpmReady } } catch {}
$pr = Get-CimInstance Win32_Processor | Select-Object -First 1
$sb = $null; try { $sb = [bool](Confirm-SecureBootUEFI -ErrorAction Stop) } catch {}
Out-Json @{
  system = @{ maker = [string]$cs.Manufacturer; model = [string]$cs.Model; name = [string]$cs.Name }
  board = @{ maker = [string]$bb.Manufacturer; model = [string]$bb.Product; version = [string]$bb.Version }
  bios = @{ maker = [string]$bios.Manufacturer; version = [string]$bios.SMBIOSBIOSVersion; date = $(if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('o') } else { '' }); uefi = ($env:firmware_type -eq 'UEFI' -or (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State')) }
  memory = @{ modules = $mods; slots = [int]$slots; total = [int64]$cs.TotalPhysicalMemory }
  gpus = $gpus; disks = $disks; monitors = $monitors
  os = @{ name = [string]$os.Caption; version = [string]$cv.DisplayVersion; build = "$($cv.CurrentBuild).$($cv.UBR)"; installed = $os.InstallDate.ToString('o'); arch = [string]$os.OSArchitecture }
  cpu = @{ socket = [string]$pr.SocketDesignation; maxclock = [int]$pr.MaxClockSpeed; count = @(Get-CimInstance Win32_Processor).Count; virtualization = [bool]$pr.VirtualizationFirmwareEnabled }
  tpm = $tpm; secureboot = $sb
}
