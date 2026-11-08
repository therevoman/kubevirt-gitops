# Windows 11 boot-source post-install (adapted from kubevirt-gitops/win2k22).
# Installs virtio-win guest tools, the QEMU guest agent and cloudbase-init, then generalizes and
# shuts down. The build Job clones the disk once the VM is off.
# Log: C:\Windows\Temp\post-install.log  (sysprep: C:\Windows\System32\Sysprep\Panther\setupact.log)
Start-Transcript -Path C:\Windows\Temp\post-install.log -Append
$ErrorActionPreference = 'Continue'
$BasePath = 'C:\Windows\Temp\Install'
New-Item $BasePath -ItemType Directory -Force | Out-Null

# Keep Windows Update from staging servicing work in the background during the build; pending
# servicing holds "reserved storage", which makes sysprep fail (0x800F0975). Removed again before sysprep.
$AU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item $AU -Force | Out-Null
Set-ItemProperty $AU NoAutoUpdate 1 -Type DWord


# The virtio-win CD-ROM, found by content (drive letters vary)
$Virtio = (Get-PSDrive -PSProvider FileSystem | Where-Object { Test-Path (Join-Path $_.Root 'virtio-win-gt-x64.msi') } | Select-Object -First 1).Root
Write-Output "virtio-win drive: $Virtio"

# Enable RDP
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'

# Trust the Red Hat driver publisher so the driver install doesn't prompt
$Cert = (Get-AuthenticodeSignature (Join-Path $Virtio 'Balloon\w11\amd64\balloon.sys')).SignerCertificate
$CertFile = Join-Path $BasePath 'redhat.cer'
[System.IO.File]::WriteAllBytes($CertFile, $Cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
Import-Certificate -FilePath $CertFile -CertStoreLocation Cert:\LocalMachine\TrustedPublisher

# virtio drivers + guest tools, then the QEMU guest agent
Start-Process msiexec.exe -Wait -ArgumentList "/i `"$(Join-Path $Virtio 'virtio-win-gt-x64.msi')`" /qn /norestart"
Start-Process msiexec.exe -Wait -ArgumentList "/i `"$(Join-Path $Virtio 'guest-agent\qemu-ga-x86_64.msi')`" /qn /norestart"

# Make sure nothing got encrypted (golden image must not be BitLocker-protected)
reg add HKLM\SYSTEM\CurrentControlSet\Control\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f
$bl = Get-BitLockerVolume -MountPoint C: -ErrorAction SilentlyContinue
if ($bl -and $bl.VolumeStatus -ne 'FullyDecrypted') {
    Disable-BitLocker -MountPoint C:
    while ((Get-BitLockerVolume -MountPoint C:).VolumeStatus -ne 'FullyDecrypted') { Start-Sleep 10 }
}

# cloudbase-init (cloud-init for Windows; used by the template's cloud-init/sysprep volumes)
$Cloudinit = Join-Path $BasePath 'CloudbaseInitSetup_Stable_x64.msi'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing https://www.cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi -OutFile $Cloudinit
Start-Process msiexec.exe -Wait -ArgumentList "/i `"$Cloudinit`" /qn /norestart"

# Sysprep fails on Appx packages installed for a user but not provisioned for all users
$Provisioned = (Get-AppxProvisionedPackage -Online).PackageName
Get-AppxPackage | Where-Object { -not $_.NonRemovable -and -not $_.IsFramework -and ($Provisioned -notcontains $_.PackageFullName) } |
    ForEach-Object { Write-Output "Removing non-provisioned Appx $($_.PackageFullName)"; Remove-AppxPackage -Package $_.PackageFullName -ErrorAction SilentlyContinue }

Remove-Item $BasePath -Recurse -Force

# cloudbase-init: only probe the metadata sources KubeVirt provides (config drive / NoCloud CD).
# The default list also polls the OpenStack/EC2/MAAS endpoints at 169.254.169.254, which adds 10-20+
# minutes of timeouts to every VM's first boot ("Getting ready" / "Still working on a few things").
$CbiConf = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf'
foreach ($f in 'cloudbase-init.conf', 'cloudbase-init-unattend.conf') {
    $p = Join-Path $CbiConf $f
    (Get-Content $p) -replace '^metadata_services=.*', 'metadata_services=cloudbaseinit.metadata.services.configdrive.ConfigDriveService,cloudbaseinit.metadata.services.nocloudservice.NoCloudConfigDriveService' |
        Set-Content $p -Encoding ASCII
    Select-String -Path $p -Pattern '^metadata_services'
}

# --- Generalize ----------------------------------------------------------------------------------
# Reboot so pending servicing completes, then run sysprep from a one-shot SYSTEM startup task.
# If sysprep fails the VM stays up (see C:\Windows\System32\Sysprep\Panther\setupact.log) and the
# build Job times out instead of cloning a bad image.
$Stage2 = 'C:\Windows\Temp\sysprep-stage2.ps1'
Set-Content -Path $Stage2 -Encoding UTF8 -Value @'
Start-Transcript -Path C:\Windows\Temp\post-install.log -Append
Unregister-ScheduledTask -TaskName BootSourceSysprep -Confirm:$false
Start-Sleep -Seconds 60
Remove-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Recurse -Force -ErrorAction SilentlyContinue
# Reserved storage (Windows 10 1903+/Server 2022+) blocks sysprep while a servicing scenario is active
$RM = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager'
if (Test-Path $RM) {
    Set-ItemProperty $RM ActiveScenario 0 -Type DWord
    dism.exe /Online /Set-ReservedStorageState /State:Disabled
}
Stop-Transcript
# Quote the whole argument: the path has spaces
$Conf = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf'
Set-Location $Conf
& C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown "/unattend:$Conf\Unattend.xml"
'@
Register-ScheduledTask -TaskName BootSourceSysprep -Force -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest `
    -Trigger (New-ScheduledTaskTrigger -AtStartup) `
    -Action (New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -File $Stage2")
Stop-Transcript
Restart-Computer -Force
