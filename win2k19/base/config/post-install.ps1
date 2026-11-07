# Find the virtio-win CD and this scripts CD by their contents (drive letters vary with the disk layout)
$V = (Get-PSDrive -PSProvider FileSystem | Where-Object { Test-Path "$($_.Root)virtio-win-gt-x64.msi" } | Select-Object -First 1).Root
if (-not $V) { Write-Error "virtio-win CD not found"; exit 1 }

# Create Workdir
$BasePath = "C:\Windows\Temp\Install"
New-item $BasePath -itemtype directory

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
Remove-item $BasePath -Recurse

# Remove AutoLogin
# reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f

# Run Sysprep and Shutdown
#
#Push-Location "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\"
#C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:Unattend.xml

# Perform windows updates
Install-Module PSWindowsUpdate -Force -AcceptLicense -Confirm
Get-WindowsUpdate
Install-WindowsUpdate -AcceptAll -AutoReboot

cmd /C 'cd "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\" && C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:Unattend.xml'

Start-Sleep -Duration (New-TimeSpan -Seconds 600); Stop-Computer
