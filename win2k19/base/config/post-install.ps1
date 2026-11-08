# Find the virtio-win CD and this scripts CD by their contents (drive letters vary with the disk layout)
$V = (Get-PSDrive -PSProvider FileSystem | Where-Object { Test-Path "$($_.Root)virtio-win-gt-x64.msi" } | Select-Object -First 1).Root
if (-not $V) { Write-Error "virtio-win CD not found"; exit 1 }

# Create Workdir
$BasePath = "C:\Windows\Temp\Install"
New-item $BasePath -itemtype directory

# Keep Windows Update from staging servicing work in the background during the build; pending
# servicing holds "reserved storage", which makes sysprep fail (0x800F0975). Removed again before sysprep.
$AU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item $AU -Force | Out-Null
Set-ItemProperty $AU NoAutoUpdate 1 -Type DWord


# Enable RDP
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name "fDenyTSConnections" -value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

# Add RedHat to Trusted Publisher
$CertName = "balloon.cer"
$ExportCert = Join-Path $BasePath -ChildPath $CertName

$Cert = (Get-AuthenticodeSignature "${V}Balloon\2k19\amd64\balloon.sys").SignerCertificate
$ExportType = [System.Security.Cryptography.X509Certificates.X509ContentType]::Cert

[System.IO.File]::WriteAllBytes($ExportCert, $Cert.Export($ExportType))
Import-Certificate -FilePath $ExportCert -CertStoreLocation Cert:\LocalMachine\TrustedPublisher

# install Guest Agent
Start-Process msiexec -Wait -ArgumentList "/i `"${V}virtio-win-gt-x64.msi`" /qn /passive"

# install Qemu Tools (Drivers)
Start-Process msiexec -Wait -ArgumentList "/i `"${V}guest-agent\qemu-ga-x86_64.msi`" /qn /passive"

# Fix Guest Agent
Start-Process "${V}vioserial\2k19\amd64\vioser.inf" -Verb install

# Get Cloud-init
Set-ExecutionPolicy Unrestricted
$Cloudinit = "CloudbaseInitSetup_Stable_x64.msi"
$CloudinitLocation =  Join-Path -Path "C:\windows\temp\" -ChildPath $Cloudinit
invoke-webrequest https://www.cloudbase.it/downloads/$Cloudinit -o $CloudinitLocation

cmd /C start /wait msiexec /i $CloudinitLocation /qn

# Cleanup
Remove-Item $BasePath -Recurse -Force

# Windows updates. No -AutoReboot: a reboot here would kill this script before sysprep runs;
# the reboot below finishes the install.
Install-Module PSWindowsUpdate -Force -AcceptLicense -Confirm:$false
Install-WindowsUpdate -AcceptAll -IgnoreReboot

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
