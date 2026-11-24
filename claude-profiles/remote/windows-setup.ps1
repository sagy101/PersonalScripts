# Windows half of the remote agent box. One line in an ELEVATED PowerShell:
#   irm https://raw.githubusercontent.com/sagy101/PersonalScripts/main/claude-profiles/remote/windows-setup.ps1 -OutFile $env:TEMP\ws.ps1; powershell -ExecutionPolicy Bypass -File $env:TEMP\ws.ps1
# First run installs WSL and asks for a reboot; run the same line again after it.
#
# Result: sshd on :22 whose shell is WSL bash (Mac key from remote/mac.pub),
# never sleeps on AC, screen off after 1 min, lid does nothing, WSL kept alive
# at logon, Remote Desktop on, Git + gh + native Claude Code, AM-PM cloned to
# %USERPROFILE%\CascadeProjects\AM-PM — then it runs wsl-setup.sh inside Ubuntu.
# Re-runnable: every step skips what is already done.
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'  # else `wsl -l` prints UTF-16 and the Ubuntu check never matches
$raw = 'https://raw.githubusercontent.com/sagy101/PersonalScripts/main/claude-profiles/remote'
function Update-Path { $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') }

# 1. WSL + Ubuntu.
if (-not (Test-Path "$env:SystemRoot\System32\bash.exe") -or -not (wsl.exe -l -q | Select-String Ubuntu)) {
  wsl.exe --install -d Ubuntu
  Write-Host 'Reboot, open Ubuntu once to create your Linux user, then run the same line again.'
  exit 0
}

# 2. OpenSSH server, shell = WSL bash, Mac key authorized.
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
Set-Service sshd -StartupType Automatic
Start-Service sshd
New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell `
  -Value "$env:SystemRoot\System32\bash.exe" -PropertyType String -Force | Out-Null
$macKey = (Invoke-RestMethod "$raw/mac.pub").Trim()
# Admin accounts read administrators_authorized_keys (ACL'd to Administrators+SYSTEM), not ~/.ssh.
$keys = "$env:ProgramData\ssh\administrators_authorized_keys"
if (-not (Test-Path $keys) -or -not (Select-String -Path $keys -SimpleMatch $macKey -Quiet)) { Add-Content -Path $keys -Value $macKey }
icacls.exe $keys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null

# 3. Power: awake forever on AC, screen off after 1 min, lid = do nothing.
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 1
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
powercfg /setactive SCHEME_CURRENT

# 4. Keep the WSL VM up at logon (it otherwise stops when the last SSH session ends).
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wsl.exe" -Argument '-d Ubuntu -e sleep infinity'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'keep-wsl-alive' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'keep-wsl-alive'

# 5. Remote Desktop: the fallback when SSH/WSL is stuck (Windows Pro/Enterprise).
#    Group id = the locale-independent name of the "Remote Desktop" firewall group.
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'

# 6. Windows tools for `claude-remote --win`: Git (Claude Code needs Git Bash), gh, Claude Code.
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

Write-Host "Done. This box: $env:COMPUTERNAME / user $env:USERNAME  (send both to the Mac)"
Write-Host 'Check sleep is not overridden by policy:'
powercfg /requests
