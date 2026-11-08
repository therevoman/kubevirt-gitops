# Windows 11 boot-source post-install (adapted from kubevirt-gitops/win2k22).
# Stage 1 (this script, FirstLogonCommands): virtio-win guest tools, QEMU guest agent, cloudbase-init,
# clone first-boot hooks. Stage 2 (sysprep-stage2.ps1, SYSTEM startup task): Windows Update rounds
# with a reboot between them, pre-sysprep checks and cleanup, then sysprep /generalize /shutdown.
# The build Job clones the disk once the VM is off.
#
# Fail fast: every step stops on error. Progress and failures go to C:\Windows\Temp\build-status.txt,
# which install.sh reads through the guest agent; a line starting "FAILED" ends the Job with an error
# (the VM is left running for debugging).
# Logs: C:\Windows\Temp\post-install.log, sysprep: C:\Windows\System32\Sysprep\Panther\setupact.log
Start-Transcript -Path C:\Windows\Temp\post-install.log -Append
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'      # Invoke-WebRequest is very slow with a progress bar

# Shared by stage 1 and stage 2
$Lib = 'C:\Windows\Temp\build-lib.ps1'
Set-Content -Path $Lib -Encoding ASCII -Value @'
$BuildStatus = 'C:\Windows\Temp\build-status.txt'
function Set-BuildStatus([string]$Status) {
    Set-Content -Path $BuildStatus -Encoding ASCII -Value "$(Get-Date -Format s) $Status"
    Write-Output "BUILD STATUS: $Status"
}
function Set-BuildFailed([string]$Stage, $Err) {
    $msg = "$($Err.Exception.Message)" -replace '\s+', ' '
    Set-BuildStatus "FAILED $Stage line $($Err.InvocationInfo.ScriptLineNumber): $msg"
}
# Clones boot on virtio-blk / virtio-scsi; the image is built on SATA, so it boots in a clone only if
# these drivers are in the driver store.
function Assert-VirtioStorageDrivers {
    $inf = (Get-WindowsDriver -Online).OriginalFileName | ForEach-Object { Split-Path $_ -Leaf }
    foreach ($d in 'viostor.inf', 'vioscsi.inf') {
        if ($inf -notcontains $d) { throw "$d is not in the driver store; clones on virtio disks would not boot" }
    }
    Write-Output 'viostor.inf and vioscsi.inf are in the driver store'
}
# Sysprep fails on Appx packages installed for a user but not provisioned for all users
function Remove-UserOnlyAppx {
    $Provisioned = (Get-AppxProvisionedPackage -Online).PackageName
    Get-AppxPackage -AllUsers | Where-Object { -not $_.NonRemovable -and -not $_.IsFramework -and ($Provisioned -notcontains $_.PackageFullName) } |
        ForEach-Object {
            Write-Output "Removing non-provisioned Appx $($_.PackageFullName)"
            Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
        }
}
'@
. $Lib
trap { Set-BuildFailed 'post-install' $_; Stop-Transcript; exit 1 }
Set-BuildStatus 'post-install started'

function Install-Msi([string]$Msi) {
    $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList "/i `"$Msi`" /qn /norestart"
    if ($p.ExitCode -notin 0, 3010) { throw "msiexec $Msi failed with exit code $($p.ExitCode)" }
}

# Keep Windows Update from staging servicing work in the background during the build; pending
# servicing holds "reserved storage", which makes sysprep fail (0x800F0975). Stage 2 installs updates
# explicitly; the clone's SetupComplete removes this policy (removing it before sysprep would let
# background updates race sysprep).
$AU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item $AU -Force | Out-Null
Set-ItemProperty $AU NoAutoUpdate 1 -Type DWord

# The virtio-win CD-ROM, found by content (drive letters vary)
$Virtio = (Get-PSDrive -PSProvider FileSystem | Where-Object { Test-Path (Join-Path $_.Root 'virtio-win-gt-x64.msi') } | Select-Object -First 1).Root
if (-not $Virtio) { throw 'virtio-win CD-ROM not found' }
Write-Output "virtio-win drive: $Virtio"

# Enable RDP
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'

# Trust the Red Hat driver publisher so the driver install doesn't prompt
$BasePath = 'C:\Windows\Temp\Install'
New-Item $BasePath -ItemType Directory -Force | Out-Null
$Cert = (Get-AuthenticodeSignature (Join-Path $Virtio 'Balloon\w11\amd64\balloon.sys')).SignerCertificate
$CertFile = Join-Path $BasePath 'redhat.cer'
[System.IO.File]::WriteAllBytes($CertFile, $Cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
Import-Certificate -FilePath $CertFile -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null

# virtio drivers + guest tools, then the QEMU guest agent (install.sh reads build-status.txt through it)
Set-BuildStatus 'installing virtio-win guest tools and the QEMU guest agent'
Install-Msi (Join-Path $Virtio 'virtio-win-gt-x64.msi')
Install-Msi (Join-Path $Virtio 'guest-agent\qemu-ga-x86_64.msi')
Assert-VirtioStorageDrivers

# Make sure nothing got encrypted (golden image must not be BitLocker-protected)
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker PreventDeviceEncryption 1 -Type DWord
$bl = Get-BitLockerVolume -MountPoint C: -ErrorAction SilentlyContinue
if ($bl -and $bl.VolumeStatus -ne 'FullyDecrypted') {
    Disable-BitLocker -MountPoint C: | Out-Null
    while ((Get-BitLockerVolume -MountPoint C:).VolumeStatus -ne 'FullyDecrypted') { Start-Sleep 10 }
}

# cloudbase-init (cloud-init for Windows; used by the template's cloud-init/sysprep volumes).
# Pinned to a GitHub release (the cloudbase.it "Stable" link moves between releases and lags GitHub;
# both serve identical MSIs). To upgrade, change both lines. 1.1.9 over 1.1.8: NoCloud accepts
# public-keys as a dict of strings, config drive locations are searched in a fixed order (CD-ROM first),
# and the bundled cryptography/urllib3/requests/oauthlib are updated.
Set-BuildStatus 'installing cloudbase-init'
$CbiUrl = 'https://github.com/cloudbase/cloudbase-init/releases/download/1.1.9/CloudbaseInitSetup_1_1_9_x64.msi'
$CbiSha256 = 'ffbf80515a7311ed00800276a6af7aab23b41d7acf13e79ce3d2d56844f638f7'
$Cloudinit = Join-Path $BasePath 'CloudbaseInitSetup_x64.msi'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing $CbiUrl -OutFile $Cloudinit
$hash = (Get-FileHash $Cloudinit -Algorithm SHA256).Hash
if ($hash -ne $CbiSha256) { throw "cloudbase-init MSI SHA256 $hash does not match the pinned $CbiSha256" }
$sig = Get-AuthenticodeSignature $Cloudinit
if ($sig.Status -ne 'Valid') { throw "cloudbase-init MSI signature is $($sig.Status)" }
Write-Output "cloudbase-init MSI signed by $($sig.SignerCertificate.Subject)"
Install-Msi $Cloudinit

Remove-UserOnlyAppx
Remove-Item $BasePath -Recurse -Force

# cloudbase-init settings, written into [DEFAULT] of both config files (replacing an existing line or
# adding one: the installer writes metadata_services only into cloudbase-init-unattend.conf).
#  - metadata_services: only the sources KubeVirt provides (config drive / NoCloud CD). The defaults
#    also poll HTTP endpoints (169.254.169.254, the DHCP server); on this network the UniFi gateway
#    answers with its login page, which cloudbase-init accepted as "CloudStack" metadata after 6+
#    minutes of timeouts on every first boot.
#  - plugins (service run): the defaults without CreateUser/SetUserPassword/SSHPublicKeys/
#    WinRMCertificateAuth. Those manage cloudbase-init's own "Admin" account: they create it with a
#    password nobody is told and, if an "Admin" already exists (e.g. from a sysprep answer file),
#    reset its password to a random value. Accounts come from a sysprep volume or the guest agent;
#    cloud-init user data (scripts, cloud-config users) still works.
$CbiConf = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf'
function Set-CbiOption([string]$File, [string]$Key, [string]$Value) {
    $p = Join-Path $CbiConf $File
    $lines = [Collections.Generic.List[string]](Get-Content $p)
    $line = "$Key=$Value"
    $i = $lines.FindIndex([Predicate[string]] { param($l) $l -match "^\s*$Key\s*=" }.GetNewClosure())
    if ($i -ge 0) { $lines[$i] = $line }
    else {
        $d = $lines.FindIndex([Predicate[string]] { param($l) $l.Trim() -eq '[DEFAULT]' }.GetNewClosure())
        if ($d -lt 0) { throw "$File has no [DEFAULT] section" }
        $lines.Insert($d + 1, $line)
    }
    Set-Content $p $lines -Encoding ASCII
    if (-not (Select-String -Path $p -SimpleMatch $line -Quiet)) { throw "could not set $Key in $File" }
    Write-Output "${File}: $line"
}
$MetadataServices = 'cloudbaseinit.metadata.services.configdrive.ConfigDriveService,cloudbaseinit.metadata.services.nocloudservice.NoCloudConfigDriveService'
foreach ($f in 'cloudbase-init.conf', 'cloudbase-init-unattend.conf') { Set-CbiOption $f metadata_services $MetadataServices }
Set-CbiOption cloudbase-init.conf plugins (@(
    'cloudbaseinit.plugins.common.mtu.MTUPlugin'
    'cloudbaseinit.plugins.windows.ntpclient.NTPClientPlugin'
    'cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin'
    'cloudbaseinit.plugins.common.networkconfig.NetworkConfigPlugin'
    'cloudbaseinit.plugins.windows.licensing.WindowsLicensingPlugin'
    'cloudbaseinit.plugins.windows.extendvolumes.ExtendVolumesPlugin'
    'cloudbaseinit.plugins.common.userdata.UserDataPlugin'
    'cloudbaseinit.plugins.windows.winrmlistener.ConfigWinRMListenerPlugin'
    'cloudbaseinit.plugins.common.localscripts.LocalScriptsPlugin'
) -join ',')

# Clone first-boot hooks.
# Honor a KubeVirt sysprep disk. Sysprep caches cloudbase-init's Unattend.xml in C:\Windows\Panther,
# which outranks an answer file on a CD, so a sysprep volume would be ignored. A first specialize
# command copies the answer file from the sysprep volume to C:\Windows\Panther\Unattend\, which
# outranks the cache when Setup looks for an answer file again at the start of oobeSystem
# (overwriting the cache itself does not work: Setup rewrites it after specialize). The oobeSystem
# pass (local accounts, OOBE settings) then uses the VM's answer file; its specialize settings
# (computer name, time zone) are already past. SetupComplete deletes the copy (it holds passwords).
$Scripts = 'C:\Windows\Setup\Scripts'
New-Item $Scripts -ItemType Directory -Force | Out-Null
Set-Content -Path "$Scripts\use-sysprep-cd.ps1" -Encoding ASCII -Value @'
# Only KubeVirt's sysprep volume is used: a CD labelled "unattendCD". Answer files on other disks
# (data disks, the install ISO, a cloud-init drive) are ignored. .NET only: no WMI during specialize.
$log = 'C:\Windows\Panther\use-sysprep-cd.log'
$cd = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'CDRom' -and $_.IsReady -and $_.VolumeLabel -eq 'unattendCD' })
if ($cd.Count -eq 0) { 'no sysprep volume (CD labelled unattendCD); using the image defaults' | Out-File $log; exit 0 }
if ($cd.Count -gt 1) { "more than one sysprep volume ($($cd.Name -join ', ')); using none" | Out-File $log; exit 0 }
$f = foreach ($n in 'Unattend.xml', 'autounattend.xml') { $p = Join-Path $cd[0].RootDirectory.FullName $n; if (Test-Path $p) { $p; break } }
if (-not $f) { "sysprep volume $($cd[0].Name) has no Unattend.xml or autounattend.xml" | Out-File $log; exit 0 }
New-Item C:\Windows\Panther\Unattend -ItemType Directory -Force | Out-Null
Copy-Item $f C:\Windows\Panther\Unattend\Unattend.xml -Force
"copied $f to C:\Windows\Panther\Unattend\Unattend.xml" | Out-File $log
exit 0
'@
# Runs as SYSTEM after setup completes, before the first logon
Set-Content -Path "$Scripts\setup-complete.ps1" -Encoding ASCII -Value @'
Start-Transcript -Path C:\Windows\Panther\setup-complete.log
# The sysprep-disk answer file copy holds passwords
Remove-Item C:\Windows\Panther\Unattend\Unattend.xml -Force -ErrorAction SilentlyContinue
# OOBE leaves its temporary account behind when an answer file creates the local accounts
if (Get-LocalUser defaultuser0 -ErrorAction SilentlyContinue) { Remove-LocalUser defaultuser0 }
# The build kept automatic updates off until sysprep; turn them back on for the clone
Remove-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Recurse -Force -ErrorAction SilentlyContinue
# Grow C: when the clone's disk is larger than the image (C: is the last partition)
$max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
$size = (Get-Partition -DriveLetter C).Size
if ($max -gt $size + 100MB) { Resize-Partition -DriveLetter C -Size $max; "C: grown from $size to $max bytes" }
# Build leftovers
Remove-Item C:\Windows\Temp\build-*, C:\Windows\Temp\sysprep-stage2.ps1 -Force -ErrorAction SilentlyContinue
Stop-Transcript
'@
Add-Content -Path "$Scripts\SetupComplete.cmd" -Encoding ASCII -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Scripts\setup-complete.ps1"

$UA = Join-Path $CbiConf 'Unattend.xml'
$U = 'urn:schemas-microsoft-com:unattend'; $W = 'http://schemas.microsoft.com/WMIConfig/2002/State'
[xml]$x = Get-Content $UA
$ns = New-Object Xml.XmlNamespaceManager $x.NameTable; $ns.AddNamespace('u', $U)
$rs = $x.SelectSingleNode("//u:settings[@pass='specialize']/u:component[@name='Microsoft-Windows-Deployment']/u:RunSynchronous", $ns)
if (-not $rs) { throw 'cloudbase-init Unattend.xml has no specialize RunSynchronous; sysprep disks would be ignored' }
foreach ($o in $rs.SelectNodes('u:RunSynchronousCommand/u:Order', $ns)) { $o.InnerText = [string]([int]$o.InnerText + 1) }
$c = $x.CreateElement('RunSynchronousCommand', $U)
$a = $x.CreateAttribute('wcm', 'action', $W); $a.Value = 'add'; [void]$c.Attributes.Append($a)
foreach ($kv in @(@('Order', '1'), @('Path', "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Scripts\use-sysprep-cd.ps1"), @('Description', 'Use the answer file from a sysprep disk'))) {
    $e = $x.CreateElement($kv[0], $U); $e.InnerText = $kv[1]; [void]$c.AppendChild($e)
}
[void]$rs.PrependChild($c)
$x.Save($UA)
Select-String -Path $UA -Pattern '<Order>|<Path>' | ForEach-Object { $_.Line.Trim() }

# --- Stage 2: Windows Update, then generalize --------------------------------------------------
# A SYSTEM startup task that runs on every boot until sysprep: each round installs the available
# updates and reboots, until Windows Update offers nothing and no reboot is pending.
$Stage2 = 'C:\Windows\Temp\sysprep-stage2.ps1'
Set-Content -Path $Stage2 -Encoding UTF8 -Value @'
Start-Transcript -Path C:\Windows\Temp\post-install.log -Append
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. C:\Windows\Temp\build-lib.ps1
trap { Set-BuildFailed 'stage2' $_; Stop-Transcript; exit 1 }
Start-Sleep -Seconds 60                       # let services settle after boot

# Windows Update rounds. Drivers and feature upgrades are excluded (virtio drivers come from
# virtio-win; the image stays on the ISO's release). A transient error reboots into another round.
$MaxRounds = 8
$RoundFile = 'C:\Windows\Temp\build-wu-round.txt'
$round = 1 + [int](Get-Content $RoundFile -ErrorAction SilentlyContinue)
Set-Content $RoundFile $round
if ($round -gt $MaxRounds) { throw "Windows Update still not done after $MaxRounds rounds; see post-install.log" }
Set-BuildStatus "windows update round $round"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$retry = $false
try {
    if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
        Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Install-Module PSWindowsUpdate -Force -AcceptLicense -Confirm:$false
    }
    Import-Module PSWindowsUpdate
    $wu = @{ NotCategory = 'Drivers', 'Upgrades'; NotTitle = 'Preview' }
    $updates = @(Get-WindowsUpdate @wu)
    if ($updates.Count -gt 0) {
        Set-BuildStatus "windows update round $($round): installing $($updates.Count) updates"
        Install-WindowsUpdate @wu -AcceptAll -IgnoreReboot | Format-Table -AutoSize | Out-String -Width 200
        $retry = $true
    }
    elseif (Get-WURebootStatus -Silent) { $retry = $true }
}
catch { Write-Output "Windows Update error in round $($round): $_"; $retry = $true }
if ($retry) { Stop-Transcript; Restart-Computer -Force; exit 0 }

Set-BuildStatus 'preparing sysprep'
Unregister-ScheduledTask -TaskName BootSourceSysprep -Confirm:$false
Assert-VirtioStorageDrivers
# Auto-logon was only for the build; don't leave it (or its password) in the image
$WL = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $WL AutoAdminLogon '0'
Remove-ItemProperty $WL -Name DefaultPassword, AutoLogonCount -ErrorAction SilentlyContinue
# Reserved storage (Windows 10 1903+/Server 2022+) blocks sysprep while a servicing scenario is active
$RM = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager'
if (Test-Path $RM) {
    Set-ItemProperty $RM ActiveScenario 0 -Type DWord
    dism.exe /Online /Set-ReservedStorageState /State:Disabled
    if ($LASTEXITCODE -ne 0) { throw "dism /Set-ReservedStorageState failed ($LASTEXITCODE)" }
}
# Again right before sysprep: the Store may have updated an app per-user since stage 1
Remove-UserOnlyAppx

Set-BuildStatus 'sysprep running'
Stop-Transcript
$Conf = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf'
Set-Location $Conf
# Quote the whole argument: the path has spaces. /quiet: a failure must not wait on a dialog.
& C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet "/unattend:$Conf\Unattend.xml"
# Success shuts the VM down; still running after 5 minutes means sysprep failed
Start-Sleep -Seconds 300
$err = Get-Content C:\Windows\System32\Sysprep\Panther\setuperr.log -Tail 3 -ErrorAction SilentlyContinue
Set-BuildStatus "FAILED sysprep: $(($err -join ' ') -replace '\s+', ' ')"
exit 1
'@
Register-ScheduledTask -TaskName BootSourceSysprep -Force -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest `
    -Trigger (New-ScheduledTaskTrigger -AtStartup) `
    -Action (New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -File $Stage2") | Out-Null
Set-BuildStatus 'post-install done; rebooting into Windows Update'
Stop-Transcript
Restart-Computer -Force
