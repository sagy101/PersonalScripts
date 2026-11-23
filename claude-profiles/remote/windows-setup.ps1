# Windows half of the remote agent box. Run in an ELEVATED PowerShell:
#   powershell -ExecutionPolicy Bypass -File windows-setup.ps1 -MacPubKey "ssh-ed25519 AAAA... mac"
# Then run remote/wsl-setup.sh inside Ubuntu.
#
# Result: sshd on :22 whose shell is WSL bash, the box never sleeps on AC,
# the screen turns off after 1 min, closing the lid does nothing, and WSL is
# kept alive at logon so herdr sessions survive between SSH connections, and
# Remote Desktop is on.
param([Parameter(Mandatory)][string]$MacPubKey)
$ErrorActionPreference = 'Stop'

# 1. WSL + Ubuntu (first run needs a reboot, then re-run this script).
if (-not (Test-Path "$env:SystemRoot\System32\bash.exe") -or -not (wsl.exe -l -q | Select-String Ubuntu)) {
  wsl.exe --install -d Ubuntu
  Write-Host 'Reboot, open Ubuntu once to create your Linux user, then re-run this script.'
  exit 0
}

# 2. OpenSSH server, shell = WSL bash.
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
Set-Service sshd -StartupType Automatic
Start-Service sshd
New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell `
  -Value "$env:SystemRoot\System32\bash.exe" -PropertyType String -Force | Out-Null

# 3. Authorize the Mac. Admin accounts read administrators_authorized_keys,
#    not ~/.ssh/authorized_keys, and it must be ACL'd to Administrators+SYSTEM.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
if ($isAdmin) {
  $keys = "$env:ProgramData\ssh\administrators_authorized_keys"
  Add-Content -Path $keys -Value $MacPubKey
  icacls.exe $keys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
} else {
  New-Item -ItemType Directory -Force "$env:USERPROFILE\.ssh" | Out-Null
  Add-Content -Path "$env:USERPROFILE\.ssh\authorized_keys" -Value $MacPubKey
}

# 4. Power: awake forever on AC, screen off after 1 min, lid = do nothing.
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 1
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
powercfg /setactive SCHEME_CURRENT

# 5. Keep the WSL VM up at logon (it otherwise stops when the last SSH session ends).
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wsl.exe" -Argument '-d Ubuntu -e sleep infinity'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'keep-wsl-alive' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'keep-wsl-alive'

# 6. Remote Desktop: the fallback when SSH/WSL is stuck (Windows Pro/Enterprise).
#    Group id = the locale-independent name of the "Remote Desktop" firewall group.
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'

Write-Host "Done. This box: $env:COMPUTERNAME  (give the Mac this name or its IP)"
Write-Host 'Check sleep is not overridden by policy:  powercfg /requests ; powercfg /a'
