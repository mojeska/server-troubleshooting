# Server troubleshooting with PowerShell

Commands I use day to day on Windows servers. Works in Windows PowerShell 5.1; most work in 7.x too.
PowerShell first. The `# OldSchool:` line under a block is the cmd-era equivalent (`netstat`, `ipconfig`, `nltest`...).
AD-specific stuff is in [ad-troubleshooting](https://github.com/mojeska/ad-troubleshooting).

Most examples run against a list of servers:

```powershell
$servers = 'app01', 'app02', 'sql01'
$servers = Get-Content .\servers.txt
$servers = (Get-ADComputer -SearchBase 'OU=Servers,DC=contoso,DC=com' -Filter *).Name
```

**Contents:** [Remoting](#remoting) · [Restart and shutdown](#restart-and-shutdown) · [Health](#health) · [Network](#network) · [DHCP](#dhcp) · [Domain membership](#domain-membership) · [Security](#security) · [Repair](#repair)

---

## Disclaimer

> [!WARNING]
> **Use at your own risk.** These commands are provided as-is, with no warranty or guarantee of any kind. The author accepts no liability for any damage, data loss, downtime or other problems that result from using them.
>
> Read and understand anything before you run it, do your own research, and test in a lab before using it in production. See the [MIT License](LICENSE) for the full terms.

## Remoting

Check WinRM is answering:

```powershell
Test-WSMan app01
# OldSchool: winrm id -r:app01
```

Interactive session on one server:

```powershell
Enter-PSSession app01
```

Same command on many servers, in parallel:

```powershell
Invoke-Command -ComputerName $servers -ScriptBlock { Get-Service Spooler }
```

Turn remoting on (on by default on Server 2012 and later):

```powershell
Enable-PSRemoting -Force
```

Non-domain or IP targets need TrustedHosts on your side:

```powershell
Set-Item WSMan:\localhost\Client\TrustedHosts -Value 'app01,10.0.0.25' -Concatenate -Force
```

---

## Restart and shutdown

Restart a group, all at once:

```powershell
Restart-Computer -ComputerName $servers -Force
# OldSchool: shutdown /r /f /t 0 /m \\app01
```

Restart one at a time and wait until each is back (PowerShell remoting answering) before the next. Use for app tiers or clusters:

```powershell
foreach ($s in $servers) {
    Restart-Computer -ComputerName $s -Force -Wait -For PowerShell -Timeout 900 -Delay 5
    Write-Output "$s is back"
}
```

Shut down:

```powershell
Stop-Computer -ComputerName $servers -Force
# OldSchool: shutdown /s /f /t 0 /m \\app01
```

Who's logged on before you reboot (`quser` shows RDP sessions too, which CIM doesn't):

```powershell
foreach ($s in $servers) { quser /server:$s }
```

Who or what restarted it (1074 = planned with reason, 6008 = unexpected, 41 = lost power):

```powershell
Get-WinEvent -ComputerName app01 -FilterHashtable @{ LogName = 'System'; Id = 1074, 6008, 41 } -MaxEvents 10 |
    Select-Object TimeCreated, Id, Message
# OldSchool: wevtutil qe System /q:"*[System[(EventID=1074)]]" /c:10 /rd:true /f:text /r:app01
```

---

## Health

### Uptime

```powershell
Invoke-Command -ComputerName $servers -ScriptBlock {
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    [pscustomobject]@{ LastBoot = $boot; UptimeDays = [math]::Round(((Get-Date) - $boot).TotalDays, 1) }
} | Select-Object PSComputerName, LastBoot, UptimeDays
# OldSchool: systeminfo /s app01 | findstr /c:"Boot Time"
```

### Pending reboot

```powershell
Invoke-Command -ComputerName $servers -ScriptBlock {
    [pscustomobject]@{
        CBS           = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        WindowsUpdate = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        FileRename    = [bool](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
    }
} | Select-Object PSComputerName, CBS, WindowsUpdate, FileRename
```

### Services

Automatic services that aren't running:

```powershell
Invoke-Command -ComputerName $servers -ScriptBlock {
    Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" | Select-Object Name, DisplayName, State
} | Select-Object PSComputerName, Name, DisplayName, State
# OldSchool: sc \\app01 query state= inactive
```

Restart a service on several servers:

```powershell
Invoke-Command -ComputerName $servers -ScriptBlock { Restart-Service Spooler -Force }
# OldSchool: sc \\app01 stop Spooler && sc \\app01 start Spooler
```

Services running under a named account (the ones that break when a password changes):

```powershell
Get-CimInstance Win32_Service -ComputerName app01 |
    Where-Object StartName -notmatch 'LocalSystem|LocalService|NetworkService|NT AUTHORITY|NT SERVICE' |
    Select-Object Name, StartName, State
```

### Processes

Top 10 by CPU, with memory:

```powershell
Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 Name, Id, CPU,
    @{ n = 'MemMB'; e = { [int]($_.WorkingSet64 / 1MB) } }
# OldSchool: tasklist /s app01 /v
```

Who owns each process (run elevated):

```powershell
Get-Process -IncludeUserName | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 Name, Id, UserName
```

Kill a hung process on a remote server:

```powershell
Invoke-Command -ComputerName app01 -ScriptBlock { Stop-Process -Name w3wp -Force }
# OldSchool: taskkill /s app01 /im w3wp.exe /f
```

### Disk

Free space on every fixed drive:

```powershell
Get-CimInstance Win32_LogicalDisk -ComputerName $servers -Filter 'DriveType=3' |
    Select-Object PSComputerName, DeviceID,
        @{ n = 'SizeGB'; e = { [int]($_.Size / 1GB) } },
        @{ n = 'FreeGB'; e = { [math]::Round($_.FreeSpace / 1GB, 1) } },
        @{ n = 'FreePct'; e = { [int](100 * $_.FreeSpace / $_.Size) } } |
    Sort-Object FreePct
# OldSchool: fsutil volume diskfree C:
```

Biggest folders under a path (slow on big drives):

```powershell
Get-ChildItem C:\ -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $bytes = (Get-ChildItem $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    [pscustomobject]@{ Folder = $_.FullName; GB = [math]::Round($bytes / 1GB, 2) }
} | Sort-Object GB -Descending
```

Clean up the component store (WinSxS). No PowerShell cmdlet for this one:

```powershell
Dism.exe /Online /Cleanup-Image /StartComponentCleanup
```

### Performance

CPU, memory and disk queue, 5 samples 2 seconds apart:

```powershell
Get-Counter -ComputerName app01 -SampleInterval 2 -MaxSamples 5 -Counter @(
    '\Processor(_Total)\% Processor Time'
    '\Memory\Available MBytes'
    '\LogicalDisk(_Total)\Avg. Disk Queue Length'
)
# OldSchool: typeperf "\Processor(_Total)\% Processor Time" -s app01 -si 2 -sc 5
```

### Event logs

Errors and criticals from the last 24 hours:

```powershell
Get-WinEvent -ComputerName app01 -FilterHashtable @{
    LogName = 'System', 'Application'; Level = 1, 2; StartTime = (Get-Date).AddHours(-24)
} | Select-Object TimeCreated, LogName, ProviderName, Id, Message
# OldSchool: wevtutil qe System /q:"*[System[(Level=1 or Level=2)]]" /c:50 /rd:true /f:text /r:app01
```

One event ID across servers:

```powershell
Invoke-Command -ComputerName $servers -ScriptBlock {
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7031; StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue
} | Select-Object PSComputerName, TimeCreated, Message
```

### Scheduled tasks

Non-Microsoft tasks and their last result (0 = success):

```powershell
Get-ScheduledTask | Where-Object TaskPath -notlike '\Microsoft\*' | ForEach-Object {
    $info = $_ | Get-ScheduledTaskInfo
    [pscustomobject]@{ Task = $_.TaskName; State = $_.State; LastRun = $info.LastRunTime; Result = $info.LastTaskResult; NextRun = $info.NextRunTime }
}
# OldSchool: schtasks /query /s app01 /fo LIST /v
```

### Installed software

From the registry (don't use `Win32_Product`, it triggers MSI repairs):

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object DisplayName | Select-Object DisplayName, DisplayVersion, Publisher, InstallDate | Sort-Object DisplayName
```

---

## Network

### Ping

```powershell
foreach ($s in $servers) { [pscustomobject]@{ Server = $s; Up = Test-Connection $s -Count 1 -Quiet } }
# OldSchool: ping -n 1 app01
```

### Is a port open?

```powershell
Test-NetConnection sql01 -Port 1433
# OldSchool: telnet sql01 1433   (Telnet Client feature) or: portqry -n sql01 -e 1433
```

Many servers and ports. Test-NetConnection is slow on closed ports, so this uses a 1-second timeout:

```powershell
$ports = 443, 1433, 3389, 5985
foreach ($s in $servers) {
    foreach ($p in $ports) {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $open = try { $tcp.ConnectAsync($s, $p).Wait(1000) } catch { $false } finally { $tcp.Dispose() }
        [pscustomobject]@{ Server = $s; Port = $p; Open = $open }
    }
}
```

Trace route:

```powershell
Test-NetConnection app01 -TraceRoute
# OldSchool: tracert app01
```

### Connections (netstat)

What's listening, with the process name:

```powershell
Get-NetTCPConnection -State Listen | Sort-Object LocalPort | Select-Object LocalAddress, LocalPort,
    @{ n = 'Process'; e = { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName } }, OwningProcess
# OldSchool: netstat -ano | findstr LISTENING     (add -b, elevated, for process names)
```

Established connections and who's on the other end:

```powershell
Get-NetTCPConnection -State Established | Select-Object LocalPort, RemoteAddress, RemotePort,
    @{ n = 'Process'; e = { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName } }
# OldSchool: netstat -ano | findstr ESTABLISHED
```

Who's connected to RDP, or to one remote address:

```powershell
Get-NetTCPConnection -LocalPort 3389 -State Established
Get-NetTCPConnection -RemoteAddress 10.1.2.3
# OldSchool: netstat -an | findstr :3389
```

UDP listeners:

```powershell
Get-NetUDPEndpoint | Sort-Object LocalPort | Select-Object LocalAddress, LocalPort, OwningProcess
# OldSchool: netstat -ano -p UDP
```

### IP, DNS and routes

```powershell
Get-NetIPConfiguration                               # IP, gateway, DNS per adapter
Get-DnsClientServerAddress -AddressFamily IPv4       # DNS servers in use
Get-NetRoute -DestinationPrefix '0.0.0.0/0'          # default gateway(s)
# OldSchool: ipconfig /all  and  route print
```

Look up a name against a specific DNS server, and clear the cache:

```powershell
Resolve-DnsName app01.contoso.com -Server 10.0.0.10
Clear-DnsClientCache
# OldSchool: nslookup app01.contoso.com 10.0.0.10  and  ipconfig /flushdns
```

### File shares and open files

Who's connected, and who has a file locked:

```powershell
Get-SmbSession -CimSession fs01 | Select-Object ClientComputerName, ClientUserName, NumOpens
Get-SmbOpenFile -CimSession fs01 | Where-Object Path -like '*budget.xlsx' | Select-Object ClientUserName, ClientComputerName, Path
# OldSchool: net session  (run on fs01)  and  openfiles /query /s fs01
```

Close it:

```powershell
Get-SmbOpenFile -CimSession fs01 | Where-Object Path -like '*budget.xlsx' | Close-SmbOpenFile -Force
# OldSchool: openfiles /disconnect /s fs01 /op "budget.xlsx" /a *
```

Shares and their permissions:

```powershell
Get-SmbShare -CimSession fs01 | Where-Object Name -notlike '*$'
Get-SmbShareAccess -CimSession fs01 -Name Data
# OldSchool: net share  (run on fs01)
```

---

## DHCP

### Client

Is the adapter on DHCP, and what did it get:

```powershell
Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress, PrefixOrigin
Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE AND DHCPEnabled=TRUE' |
    Select-Object Description, IPAddress, DHCPServer, DHCPLeaseObtained, DHCPLeaseExpires
# OldSchool: ipconfig /all
```

Release and renew:

```powershell
$nic = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE AND DHCPEnabled=TRUE'
$nic | Invoke-CimMethod -MethodName ReleaseDHCPLease
$nic | Invoke-CimMethod -MethodName RenewDHCPLease
# OldSchool: ipconfig /release  then  ipconfig /renew
```

A `169.254.x.x` address means no DHCP server answered. Check the VLAN, the IP helper on the switch, and the scope.

### Server (DhcpServer module)

Scopes and how full they are:

```powershell
Get-DhcpServerv4Scope -ComputerName dhcp01 | Select-Object ScopeId, Name, State, StartRange, EndRange, LeaseDuration
Get-DhcpServerv4ScopeStatistics -ComputerName dhcp01 | Select-Object ScopeId, Free, InUse, PercentageInUse | Sort-Object PercentageInUse -Descending
# OldSchool: netsh dhcp server \\dhcp01 show scope
```

Find a lease by IP, MAC or name:

```powershell
Get-DhcpServerv4Lease -ComputerName dhcp01 -IPAddress 10.20.30.45
Get-DhcpServerv4Scope -ComputerName dhcp01 | Get-DhcpServerv4Lease -ComputerName dhcp01 |
    Where-Object { $_.ClientId -eq '00-15-5d-01-02-03' -or $_.HostName -like 'pc123*' }
```

Reservations, and adding one:

```powershell
Get-DhcpServerv4Reservation -ComputerName dhcp01 -ScopeId 10.20.30.0
Add-DhcpServerv4Reservation -ComputerName dhcp01 -ScopeId 10.20.30.0 -IPAddress 10.20.30.50 -ClientId '00-15-5d-01-02-03' -Name 'printer-2f'
# OldSchool: netsh dhcp server \\dhcp01 scope 10.20.30.0 show reservedip
```

Scope options (gateway, DNS, domain):

```powershell
Get-DhcpServerv4OptionValue -ComputerName dhcp01 -ScopeId 10.20.30.0
```

Failover state between partners:

```powershell
Get-DhcpServerv4Failover -ComputerName dhcp01 | Select-Object Name, PartnerServer, Mode, State, ScopeId
```

DHCP servers authorized in AD (an unauthorized Windows DHCP server won't hand out leases):

```powershell
Get-DhcpServerInDC
```

Audit logs, one file per weekday, for "who had this IP at 9am Tuesday":

```powershell
Get-ChildItem \\dhcp01\c$\Windows\System32\dhcp\DhcpSrvLog-*.log
Select-String -Path \\dhcp01\c$\Windows\System32\dhcp\DhcpSrvLog-Tue.log -Pattern '10.20.30.45'
```

---

## Domain membership

### Which DC is this machine using?

```powershell
$env:LOGONSERVER                                                                  # DC that logged the current user on
[DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().FindDomainController().Name   # DC it finds now (no RSAT needed)
Get-ADDomainController -Discover | Select-Object Name, Site                       # same, with RSAT
# OldSchool: nltest /dsgetdc:contoso.com  and  echo %LOGONSERVER%
```

On a remote machine:

```powershell
Invoke-Command -ComputerName app01 -ScriptBlock {
    [DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().FindDomainController().Name
}
```

The DC the secure channel is on (no PowerShell equivalent): `nltest /sc_query:contoso.com`.

### Can it reach a DC?

DNS first, then the ports logons need (Kerberos 88, LDAP 389, SMB 445, RPC 135):

```powershell
Resolve-DnsName _ldap._tcp.dc._msdcs.contoso.com -Type SRV
foreach ($p in 88, 135, 389, 445, 3268) {
    [pscustomobject]@{ Port = $p; Open = Test-NetConnection dc01 -Port $p -InformationLevel Quiet -WarningAction SilentlyContinue }
}
# OldSchool: nslookup -type=SRV _ldap._tcp.dc._msdcs.contoso.com
```

### "The trust relationship between this workstation and the primary domain failed"

The computer account password is out of sync, typically after a VM snapshot revert or a
machine offline for a long time. Log on with a local admin account (or cached
credentials) and run it in Windows PowerShell 5.1.

Check:

```powershell
Test-ComputerSecureChannel -Verbose
# OldSchool: nltest /sc_verify:contoso.com
```

Repair without rejoining (no reboot needed):

```powershell
Test-ComputerSecureChannel -Repair -Credential contoso\admin
# OldSchool: nltest /sc_reset:contoso.com
```

If that fails, reset the machine password against a specific DC:

```powershell
Reset-ComputerMachinePassword -Server dc01 -Credential contoso\admin
# OldSchool: netdom resetpwd /server:dc01 /userd:contoso\admin /passwordd:*
```

Last resort, rejoin. Moves it to a workgroup and back, with two reboots. The computer object
and its group memberships are kept:

```powershell
Remove-Computer -UnjoinDomainCredential contoso\admin -WorkgroupName TEMP -Force -Restart
# after the reboot, as local admin:
Add-Computer -DomainName contoso.com -Credential contoso\admin -Restart
# OldSchool: netdom remove / netdom join (or System Properties > Computer Name)
```

### Cached credentials

How many logons the machine caches (default 10). Lets users log on when no DC is reachable:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name CachedLogonsCount
```

---

## Security

### Firewall

Profiles on or off:

```powershell
Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction
# OldSchool: netsh advfirewall show allprofiles state
```

Enabled inbound allow rules with their ports:

```powershell
Get-NetFirewallRule -Enabled True -Direction Inbound -Action Allow | ForEach-Object {
    $pf = $_ | Get-NetFirewallPortFilter
    [pscustomobject]@{ Rule = $_.DisplayName; Profile = $_.Profile; Protocol = $pf.Protocol; Port = $pf.LocalPort -join ',' }
} | Sort-Object Rule
# OldSchool: netsh advfirewall firewall show rule name=all dir=in
```

Which rule covers a port:

```powershell
Get-NetFirewallPortFilter | Where-Object LocalPort -eq 1433 | Get-NetFirewallRule | Select-Object DisplayName, Enabled, Action
```

Open a port:

```powershell
New-NetFirewallRule -DisplayName 'SQL 1433' -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow -Profile Domain
# OldSchool: netsh advfirewall firewall add rule name="SQL 1433" dir=in action=allow protocol=TCP localport=1433 profile=domain
```

### Patches

Last 10 updates installed:

```powershell
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 10 HotFixID, Description, InstalledOn
# OldSchool: systeminfo | findstr KB
```

Last patch date across servers:

```powershell
Invoke-Command -ComputerName $servers -ScriptBlock {
    Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 1 HotFixID, InstalledOn
} | Select-Object PSComputerName, HotFixID, InstalledOn | Sort-Object InstalledOn
```

Is a specific KB installed:

```powershell
Get-HotFix -Id KB5044281 -ComputerName app01 -ErrorAction SilentlyContinue
```

### Local administrators

```powershell
Invoke-Command -ComputerName $servers -ScriptBlock { Get-LocalGroupMember Administrators } |
    Select-Object PSComputerName, Name, ObjectClass, PrincipalSource
# OldSchool: net localgroup administrators
```

`Get-LocalGroupMember` fails if the group holds an orphaned SID. Fall back to `net localgroup administrators`.

### Sessions and sign-ins

Console user (PowerShell), then all sessions including RDP, and logging one off (no PowerShell equivalent for these two):

```powershell
Get-CimInstance Win32_ComputerSystem -ComputerName app01 | Select-Object UserName
quser /server:app01
logoff 3 /server:app01
```

Failed sign-ins in the last day (4625):

```powershell
Get-WinEvent -ComputerName app01 -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = (Get-Date).AddDays(-1) } |
    Select-Object TimeCreated, @{ n = 'User'; e = { $_.Properties[5].Value } }, @{ n = 'Source'; e = { $_.Properties[19].Value } }
```

### Certificates

Machine certificates expiring in the next 60 days:

```powershell
Invoke-Command -ComputerName $servers -ScriptBlock {
    Get-ChildItem Cert:\LocalMachine\My | Where-Object NotAfter -lt (Get-Date).AddDays(60)
} | Select-Object PSComputerName, Subject, NotAfter, Thumbprint
# OldSchool: certutil -store My
```

### Defender and BitLocker

```powershell
Get-MpComputerStatus | Select-Object AMRunningMode, RealTimeProtectionEnabled, AntivirusSignatureLastUpdated
Get-BitLockerVolume | Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionPercentage
```

---

## Repair

Component store health and repair (the DISM PowerShell module), then a system file check:

```powershell
Repair-WindowsImage -Online -ScanHealth
Repair-WindowsImage -Online -RestoreHealth
sfc /scannow          # no PowerShell equivalent
# OldSchool: Dism /Online /Cleanup-Image /ScanHealth  and  /RestoreHealth
```

Windows Update log (writes WindowsUpdate.log to the desktop):

```powershell
Get-WindowsUpdateLog
```

Reset Windows Update components:

```powershell
Stop-Service wuauserv, bits, cryptsvc -Force
Rename-Item C:\Windows\SoftwareDistribution SoftwareDistribution.old
Rename-Item C:\Windows\System32\catroot2 catroot2.old
Start-Service wuauserv, bits, cryptsvc
```
