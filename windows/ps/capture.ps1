# Captures du bureau, une image par écran, plus le fond d'écran et la liste des
# icônes. Les fenêtres sont réduites le temps de la capture puis restaurées.
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -Namespace Bao -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);'
[void][Bao.Dpi]::SetProcessDpiAwarenessContext([IntPtr]-4)
$dir = [string]$A.dir
[void](New-Item -ItemType Directory -Force -Path $dir)
$shell = New-Object -ComObject Shell.Application
if ($A.minimize) { $shell.MinimizeAll(); Start-Sleep -Milliseconds 1200 }
$files = @()
try {
  $i = 0
  foreach ($s in [Windows.Forms.Screen]::AllScreens) {
    $i++
    $b = $s.Bounds
    $bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.X, $b.Y, 0, 0, $b.Size)
    $f = Join-Path $dir "Bureau-ecran-$i.png"
    $bmp.Save($f, [Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    $files += $f
  }
} finally {
  if ($A.minimize) { $shell.UndoMinimizeALL() }
}
$wall = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).WallPaper
if ($wall -and (Test-Path -LiteralPath $wall)) { Copy-Item -LiteralPath $wall -Destination (Join-Path $dir ("Fond-ecran" + [IO.Path]::GetExtension($wall))) -ErrorAction SilentlyContinue }
$desk = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'))
Get-ChildItem -LiteralPath $desk -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | Select-Object -ExpandProperty Name | Sort-Object | Set-Content -LiteralPath (Join-Path $dir 'Elements-du-bureau.txt') -Encoding UTF8
Out-Json @{ files = $files }
