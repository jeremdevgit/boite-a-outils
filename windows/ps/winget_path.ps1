# Resolve the installed Microsoft package, never an App Execution Alias or PATH entry.
$paths = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue |
  Where-Object { $_.PackageFamilyName -ceq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' } |
  ForEach-Object { [string]$_.InstallLocation })
Out-Json @{ paths = $paths }
