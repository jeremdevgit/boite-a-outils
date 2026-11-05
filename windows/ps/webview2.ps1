# Installe le moteur WebView2 : programme officiel de Microsoft, signature
# vérifiée et fichier verrouillé en écriture jusqu'à la fin de son exécution.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
$dir = Join-Path ([IO.Path]::GetTempPath()) ("bao-" + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $dir -Force)
$f = Join-Path $dir 'MicrosoftEdgeWebview2Setup.exe'
$lock = $null
try {
  Invoke-WebRequest -UseBasicParsing -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $f -TimeoutSec 120 -ErrorAction Stop
  $lock = [IO.File]::Open($f, 'Open', 'Read', 'Read')
  $s = Get-AuthenticodeSignature -LiteralPath $f
  if ($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'signature du fichier téléchargé non valide' }
  $p = Start-Process -FilePath $f -ArgumentList '/silent', '/install' -Wait -PassThru -ErrorAction Stop
  Out-Json @{ ok = ($p.ExitCode -eq 0); code = $p.ExitCode }
} finally {
  if ($lock) { $lock.Dispose() }
  Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
