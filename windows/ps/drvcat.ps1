# Catalogue Microsoft Update : recherche par identifiant matériel et
# installation dans l'application (téléchargement du .cab, pnputil).
# L'identifiant complet (avec SUBSYS et REV) ne donne presque jamais de
# résultat : on raccourcit jusqu'à en trouver.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = 'https://www.catalog.update.microsoft.com'
function Get-Page($u) { (Invoke-WebRequest -UseBasicParsing -Uri $u -TimeoutSec 60 -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)').Content }
function Clean($s) { [Net.WebUtility]::HtmlDecode(($s -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()) }

if ($A.action -eq 'search') {
  $ids = @($A.hwids | Where-Object { $_ } | ForEach-Object { [string]$_ })
  $queries = [Collections.Generic.List[string]]::new()
  foreach ($h in $ids) {
    $parts = ($h -replace '&REV_[0-9A-F]+$', '') -split '&'
    for ($n = $parts.Count; $n -ge 1; $n--) {
      $q = ($parts[0..($n - 1)] -join '&')
      # un identifiant réduit à son bus (PCI\VEN_10DE) ramènerait tout le fabricant
      if ($n -eq 1 -and $parts.Count -gt 1) { break }
      if (-not $queries.Contains($q)) { $queries.Add($q) }
    }
  }
  $win11 = [Environment]::OSVersion.Version.Build -ge 22000
  $used = ''; $rows = @()
  foreach ($q in $queries) {
    $html = Get-Page "$base/Search.aspx?q=$([uri]::EscapeDataString($q))"
    $rows = @([regex]::Matches($html, '(?s)<tr id=["'']([0-9a-f-]{36})_R\d+["''].*?</tr>') | ForEach-Object {
        $id = $_.Groups[1].Value; $t = $_.Value
        $c = @(foreach ($k in 1..5) { $m = [regex]::Match($t, "(?s)id=""${id}_C${k}_R\d+"">(.*?)</td>"); Clean $m.Groups[1].Value })
        $sz = [regex]::Match($t, "_originalSize"">(\d+)<").Groups[1].Value
        $d = [datetime]::MinValue; [void][datetime]::TryParse($c[3], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)
        [pscustomobject]@{ id = $id; title = $c[0]; products = $c[1]; class = $c[2]; date = $(if ($d -ne [datetime]::MinValue) { $d.ToString('o') } else { '' }); version = $c[4]; size = [int64]$(if ($sz) { $sz } else { 0 }); fits = $(if ($win11) { $c[1] -match 'Windows 11' } else { $c[1] -match 'Windows 10' }) }
      })
    if ($rows.Count) { $used = $q; break }
  }
  # une même version est publiée pour plusieurs éditions de Windows : on garde la plus adaptée
  $best = @{}
  foreach ($r in $rows | Sort-Object { -[int]$_.fits }, { $_.products -notmatch 'and later' }) { $k = "$($r.title)|$($r.version)"; if (-not $best.ContainsKey($k)) { $best[$k] = $r } }
  $list = @($best.Values | Where-Object { $_.title -notmatch 'ARM64' } | Sort-Object @{ e = { [int]$_.fits }; Descending = $true }, @{ e = { if ($_.date) { [datetime]$_.date } else { [datetime]'1900-01-01' } }; Descending = $true } | Select-Object -First 15)
  Out-Json @{ query = $used; items = $list }; return
}

if ($A.action -eq 'install') {
  $id = [string]$A.id
  if ($id -notmatch '^[0-9a-f-]{36}$') { throw 'Identifiant de mise à jour invalide' }
  $body = 'updateIDs=' + [uri]::EscapeDataString("[{`"size`":0,`"languages`":`"`",`"uidInfo`":`"$id`",`"updateID`":`"$id`"}]")
  $html = (Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$base/DownloadDialog.aspx" -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 60).Content
  $urls = @([regex]::Matches($html, "\.url = '([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -match '^https?://[^/]*(windowsupdate\.com|microsoft\.com)/' })
  if (-not $urls) { throw 'Le catalogue ne fournit pas de fichier pour ce pilote' }
  $dir = Join-Path $env:TEMP ("bao_drv_" + [guid]::NewGuid().ToString('N'))
  $ext = Join-Path $dir 'pilote'
  New-Item -ItemType Directory -Force $ext | Out-Null
  try {
    foreach ($u in $urls) {
      $f = Join-Path $dir ([IO.Path]::GetFileName(([uri]$u).AbsolutePath))
      Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $f -TimeoutSec 1800
      $sig = Get-AuthenticodeSignature $f
      if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw "Fichier téléchargé non signé par Microsoft ($($sig.Status))" }
      $out = & "$env:SystemRoot\System32\expand.exe" -F:* $f $ext 2>&1
      if ($LASTEXITCODE) { throw "Extraction impossible : $($out -join ' ')" }
    }
    # certains paquets contiennent eux-mêmes des .cab
    foreach ($c in Get-ChildItem $ext -Recurse -Filter *.cab) { $sub = Join-Path $c.DirectoryName $c.BaseName; New-Item -ItemType Directory -Force $sub | Out-Null; & "$env:SystemRoot\System32\expand.exe" -F:* $c.FullName $sub | Out-Null }
    if (-not (Get-ChildItem $ext -Recurse -Filter *.inf)) { throw 'Le paquet ne contient aucun pilote (.inf)' }
    $log = & "$env:SystemRoot\System32\pnputil.exe" /add-driver (Join-Path $ext '*.inf') /subdirs /install 2>&1
    $code = $LASTEXITCODE
    $text = ($log | ForEach-Object { [string]$_ }) -join "`n"
    $updated = [regex]::Matches($text, '(?im)(installé|installed|updated|mis à jour).*(périphérique|device)').Count
    Out-Json @{ ok = ($code -eq 0 -or $code -eq 3010); code = $code; reboot = ($code -eq 3010); updated = $updated; log = $text }
  } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
  return
}
throw 'Action inconnue'
