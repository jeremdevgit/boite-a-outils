# Outils Sysinternals : téléchargés depuis le site officiel de Microsoft
# (live.sysinternals.com), gardés seulement si leur signature Microsoft est valide.
$dir = Join-Path $env:BAO_DATA 'sysinternals'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
function Check([string]$f) {
  $s = Get-AuthenticodeSignature -LiteralPath $f
  return ($s.Status -eq 'Valid' -and $s.SignerCertificate.Subject -match 'O=Microsoft Corporation')
}
foreach ($f in @($A.files)) { if ($f -notmatch '^[A-Za-z0-9_-]+\.exe$') { throw "Nom de fichier refusé : $f" } }
switch ($A.action) {
  'get' {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($f in @($A.files)) {
      $tmp = Join-Path $dir "$f.part"
      Invoke-WebRequest -Uri "https://live.sysinternals.com/$f" -OutFile $tmp -UseBasicParsing
      if (-not (Check $tmp)) { Remove-Item -LiteralPath $tmp -Force; throw "$f : signature Microsoft invalide, fichier refusé" }
      Move-Item -LiteralPath $tmp -Destination (Join-Path $dir $f) -Force
    }
    Out-Json @{ ok = $true }; return
  }
  'verify' {
    $p = Join-Path $dir @($A.files)[0]
    if (-not (Test-Path -LiteralPath $p)) { throw "Outil non téléchargé" }
    if (-not (Check $p)) { Remove-Item -LiteralPath $p -Force; throw "Signature Microsoft invalide : fichier supprimé, téléchargez-le à nouveau" }
    Out-Json @{ ok = $true; path = $p }; return
  }
  'remove' { foreach ($f in Get-ChildItem -LiteralPath $dir -File) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }; Out-Json @{ ok = $true }; return }
}
throw "action inconnue"
