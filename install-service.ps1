<#
.SYNOPSIS
    Installs the Reverse SSH Tunnel as a Windows Scheduled Task that runs at boot.

.DESCRIPTION
    Creates a scheduled task that:
    - Runs at system startup (before user login)
    - Runs under the current user account
    - Restarts on failure
    - Runs the reverse-tunnel.ps1 script persistently

.NOTES
    Run this script AS ADMINISTRATOR.
#>

param(
    [string]$TaskName = "ReverseTunnelToVPS",
    [string]$ScriptPath = "",
    [switch]$Uninstall
)

# Determine script path
if ([string]::IsNullOrEmpty($ScriptPath)) {
    $ScriptPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) "reverse-tunnel.ps1"
}

if ($Uninstall) {
    Write-Host "Removing scheduled task '$TaskName'..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Task removed." -ForegroundColor Green
    exit 0
}

# Check admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Run this script as Administrator!" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $ScriptPath)) {
    Write-Host "ERROR: Script not found: $ScriptPath" -ForegroundColor Red
    exit 1
}

Write-Host "Installing Reverse SSH Tunnel as Scheduled Task..." -ForegroundColor Cyan
Write-Host "  Task Name:   $TaskName" -ForegroundColor Gray
Write-Host "  Script Path: $ScriptPath" -ForegroundColor Gray

# Remove existing task if present
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

# Create the action: run PowerShell hidden with the tunnel script
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

# Trigger: at system startup
$triggerBoot = New-ScheduledTaskTrigger -AtStartup

# Also trigger at user logon as backup
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

# Settings
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 9999)

# Principal: run as current user, highest privileges
$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType S4U `
    -RunLevel Highest

# Register the task
Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger @($triggerBoot, $triggerLogon) `
    -Settings $settings `
    -Principal $principal `
    -Description "Maintains a persistent reverse SSH tunnel to VPS for remote management." `
    -Force

Write-Host ""
Write-Host "SUCCESS: Scheduled task '$TaskName' installed!" -ForegroundColor Green
Write-Host ""
Write-Host "Commands:" -ForegroundColor Cyan
Write-Host "  Start now:     Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Gray
Write-Host "  Check status:  Get-ScheduledTask -TaskName '$TaskName' | Select State" -ForegroundColor Gray
Write-Host "  View logs:     Get-Content ~\.ssh\tunnel-logs\tunnel-*.log -Tail 20" -ForegroundColor Gray
Write-Host "  Uninstall:     .\install-service.ps1 -Uninstall" -ForegroundColor Gray
