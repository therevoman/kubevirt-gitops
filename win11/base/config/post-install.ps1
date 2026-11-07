# Windows 11 boot-source post-install (adapted from kubevirt-gitops/win2k22).
# Installs virtio-win guest tools, the QEMU guest agent and cloudbase-init, then generalizes and
# shuts down. The build Job clones the disk once the VM is off.
# Log: C:\Windows\Temp\post-install.log  (sysprep: C:\Windows\System32\Sysprep\Panther\setupact.log)
Start-Transcript -Path C:\Windows\Temp\post-install.log -Append
$ErrorActionPreference = 'Continue'
$BasePath = 'C:\Windows\Temp\Install'
New-Item $BasePath -ItemType Directory -Force | Out-Null

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
Stop-Transcript

# Generalize with cloudbase-init's unattend and power off. If this fails the VM stays up
# (see the Panther log); the build Job then times out instead of cloning a bad image.
$Conf = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf'
Start-Process -Wait -WorkingDirectory $Conf -FilePath C:\Windows\System32\Sysprep\sysprep.exe `
    -ArgumentList '/generalize', '/oobe', '/shutdown', "/unattend:$Conf\Unattend.xml"
