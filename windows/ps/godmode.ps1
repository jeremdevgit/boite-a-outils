# Mode Dieu : les ~200 réglages du Panneau de configuration rassemblés par
# Windows (dossier spécial {ED7BA470-…}), avec leur rubrique et leurs mots-clés.
$sh = New-Object -ComObject Shell.Application
$ns = $sh.NameSpace('shell:::{ED7BA470-8E54-465E-825C-99712043E01C}')
$out = New-Object System.Collections.ArrayList
foreach ($i in $ns.Items()) {
  [void]$out.Add([ordered]@{ name = [string]$i.Name; cat = [string]$ns.GetDetailsOf($i, 1); keys = [string]$ns.GetDetailsOf($i, 2); path = [string]$i.Path })
}
Out-Json @{ items = $out }
