# Windows half of the remote agent box. One line in an ELEVATED PowerShell:
#   irm https://raw.githubusercontent.com/sagy101/PersonalScripts/main/claude-profiles/remote/windows-setup.ps1 -OutFile $env:TEMP\ws.ps1; powershell -ExecutionPolicy Bypass -File $env:TEMP\ws.ps1
# First run installs WSL and asks for a reboot; run the same line again after it.
#
# Result: sshd on :22 (default cmd shell; claude-remote calls wsl.exe itself;
# Mac key from remote/mac.pub), never sleeps on AC, screen off after 1 min, lid
# does nothing, an "Agent mode" desktop shortcut (Ctrl+Alt+K) that locks +
# blanks the screen, a herdr server started at logon, Remote Desktop on, Git + gh + native Claude Code, AM-PM cloned to
# %USERPROFILE%\CascadeProjects\AM-PM — then it runs wsl-setup.sh inside Ubuntu.
# Re-runnable: every step skips what is already done.
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'  # else `wsl -l` prints UTF-16 and the Ubuntu check never matches
$raw = 'https://raw.githubusercontent.com/sagy101/PersonalScripts/main/claude-profiles/remote'
function Update-Path { $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') }

# 1. WSL + Ubuntu. (Store WSL ships no bash.exe — only the distro list counts.)
$distros = (wsl.exe -l -q) -replace "`0", ''  # strip UTF-16 NULs if WSL_UTF8 is ignored
if (-not ($distros -match '^Ubuntu')) {
  wsl.exe --install -d Ubuntu
  Write-Host 'Reboot, open Ubuntu once to create your Linux user, then run the same line again.'
  exit 0
}

# 2. OpenSSH server (default cmd shell): key-only logins, exactly the Mac key.
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
Set-Service sshd -StartupType Automatic
Start-Service sshd  # first start also writes the default sshd_config
$macKey = (Invoke-RestMethod "$raw/mac.pub").Trim()
# Admin accounts read administrators_authorized_keys (ACL'd to Administrators+SYSTEM), not ~/.ssh.
# Overwritten, not appended: a rotated mac.pub must also revoke the old key.
$keys = "$env:ProgramData\ssh\administrators_authorized_keys"
Set-Content -Path $keys -Value $macKey -Encoding ascii
icacls.exe $keys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
# No passwords: nobody on the network can guess their way into this admin account.
# First line, because sshd keeps the first value of a keyword (the default file ends in a Match block).
$cfg = "$env:ProgramData\ssh\sshd_config"
if (-not (Select-String -Path $cfg -Pattern '^PasswordAuthentication no' -Quiet)) {
  Set-Content -Path $cfg -Value (@('PasswordAuthentication no') + (Get-Content $cfg)) -Encoding ascii
}
& "$env:SystemRoot\System32\OpenSSH\sshd.exe" -t
if ($LASTEXITCODE -ne 0) { throw "sshd_config is invalid: $cfg" }
Restart-Service sshd

# 3. Power: awake forever on AC, screen off after 1 min, lid = do nothing.
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 1
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
powercfg /setactive SCHEME_CURRENT

# 3b. "Agent mode" = lock + screen off NOW: desktop shortcut, hotkey Ctrl+Alt+K.
#     The box keeps running (step 3); Win+L alone also works, the screen then goes off after 1 min.
$box = "$env:USERPROFILE\agent-box"
New-Item -ItemType Directory -Force $box | Out-Null
Set-Content -Path "$box\lock-screen-off.ps1" -Value @'
Add-Type -Namespace AgentBox -Name User32 -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool LockWorkStation();
[DllImport("user32.dll")] public static extern int SendMessage(int hWnd, int msg, int wParam, int lParam);
"@
[AgentBox.User32]::LockWorkStation() | Out-Null
Start-Sleep -Seconds 1  # let the lock screen draw, or it wakes the display again
[AgentBox.User32]::SendMessage(0xFFFF, 0x0112, 0xF170, 2) | Out-Null  # broadcast SC_MONITORPOWER = off
'@
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut("$([Environment]::GetFolderPath('Desktop'))\Agent mode (lock + screen off).lnk")
$lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$box\lock-screen-off.ps1`""
$lnk.Hotkey = 'CTRL+ALT+K'
$lnk.Save()

# 4. herdr server at logon, in your desktop session, so `claude-remote --session`
#    agents (and `herdr --remote` from the Mac) outlive any one SSH connection.
if (-not (Get-Command herdr -ErrorAction SilentlyContinue)) { Invoke-RestMethod https://herdr.dev/install.ps1 | Invoke-Expression; Update-Path }
$herdr = (Get-Command herdr).Source
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -Argument "-NoProfile -WindowStyle Hidden -Command & '$herdr' server"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'herdr-server' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'herdr-server'

# 5. Remote Desktop: the fallback when SSH/WSL is stuck (Windows Pro/Enterprise).
#    Group id = the locale-independent name of the "Remote Desktop" firewall group.
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'

# 6. Windows tools for `claude-remote --win`: Git (Claude Code needs Git Bash), gh, Claude Code.
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget missing: install "App Installer" from the Microsoft Store, then re-run.' }
foreach ($id in 'Git.Git', 'GitHub.cli') {
  winget list --id $id -e | Out-Null
  if ($LASTEXITCODE -ne 0) { winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements }
}
if (-not (Test-Path "$env:USERPROFILE\.local\bin\claude.exe")) { Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression }
Update-Path

# 7. GitHub: one browser login here; WSL borrows this token (wsl-setup.sh).
# via cmd: PS 5.1 turns a redirected native stderr into a terminating error under 'Stop'.
cmd.exe /c 'gh auth status >nul 2>&1'
if ($LASTEXITCODE -ne 0) { gh auth login --hostname github.com --git-protocol https --web }
gh auth setup-git
$amPm = "$env:USERPROFILE\CascadeProjects\AM-PM"
if (-not (Test-Path $amPm)) { gh repo clone PFPT-Internal/am-pm $amPm }

# 8. Linux half (interactive: LiteLLM key + the two subscription tokens).
wsl.exe -d Ubuntu -e bash -c "bash <(curl -fsSL $raw/wsl-setup.sh)"
if ($LASTEXITCODE -ne 0) { throw "wsl-setup.sh failed (exit $LASTEXITCODE)" }

Write-Host "Done. This box: $env:COMPUTERNAME / user $env:USERNAME / $(& $herdr --version)  (send all three to the Mac)"
Write-Host 'Check sleep is not overridden by policy:'
powercfg /requests
