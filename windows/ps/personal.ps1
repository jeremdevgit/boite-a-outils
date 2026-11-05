# Personnalisation et réseau : prévient les fenêtres d'un changement de
# réglage (thème, couleurs), serveurs DNS des cartes réseau.
switch ($A.action) {
  'broadcast' {
    Add-Type -Namespace Bao -Name Msg -MemberDefinition '[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, UIntPtr w, string l, uint f, uint t, out UIntPtr r);' -ErrorAction SilentlyContinue
    $r = [UIntPtr]::Zero
    foreach ($s in 'ImmersiveColorSet', 'WindowsThemeElement', 'Policy') { [void][Bao.Msg]::SendMessageTimeout([IntPtr]0xFFFF, 0x1A, [UIntPtr]::Zero, $s, 2, 1000, [ref]$r) }
    Out-Json @{ ok = $true }; return
  }
  'dns' {
    $out = @()
    foreach ($a in Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up') {
      $d = Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
      $auto = $true
      try { $p = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($a.InterfaceGuid)" -ErrorAction Stop; $auto = -not $p.NameServer } catch {}
      $out += , @{ index = $a.ifIndex; name = $a.Name; desc = $a.InterfaceDescription; servers = @($d.ServerAddresses); auto = $auto }
    }
    Out-Json @{ adapters = $out }; return
  }
  'setdns' {
    $prev = @()
    foreach ($i in @($A.adapters)) {
      $a = Get-NetAdapter -InterfaceIndex $i -ErrorAction Stop
      $p = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($a.InterfaceGuid)" -ErrorAction SilentlyContinue
      $was = if ($p.NameServer) { @($p.NameServer -split '[, ]+' | Where-Object { $_ }) } else { @() }
      $prev += , @{ index = $i; servers = $was }
      if (@($A.servers).Count) { Set-DnsClientServerAddress -InterfaceIndex $i -ServerAddresses @($A.servers) }
      else { Set-DnsClientServerAddress -InterfaceIndex $i -ResetServerAddresses }
    }
    Clear-DnsClientCache
    Out-Json @{ ok = $true; detail = "DNS : $(if (@($A.servers).Count) { @($A.servers) -join ', ' } else { 'automatiques' })"; undo = @{ script = 'personal'; args = @{ action = 'restoredns'; items = $prev } } }; return
  }
  'restoredns' {
    foreach ($i in @($A.items)) {
      if (@($i.servers).Count) { Set-DnsClientServerAddress -InterfaceIndex $i.index -ServerAddresses @($i.servers) }
      else { Set-DnsClientServerAddress -InterfaceIndex $i.index -ResetServerAddresses }
    }
    Clear-DnsClientCache
    Out-Json @{ ok = $true }; return
  }
}
throw "action inconnue"
