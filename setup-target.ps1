<#
.SYNOPSIS
    One-click target device setup for Remote Management System.
    Run this script on any Windows PC you want to manage remotely.

.DESCRIPTION
    This script:
    1. Installs & starts OpenSSH Server
    2. Downloads client files from your GitHub repo
    3. Saves the shared SSH key for the tunnel
    4. Configures and starts the reverse tunnel
    5. Installs the tunnel as a boot service

.NOTES
    Run as Administrator on the target PC.
    Usage: & ([scriptblock]::Create((irm "URL"))) -DeviceName "PC1" -Port 2201 -SharedKey "BASE64STRING"
#>

param (
    [Parameter(Mandatory=$true)] [string]$DeviceName,
    [Parameter(Mandatory=$true)] [string]$Port,
    [Parameter(Mandatory=$true)] [string]$SharedKey
)

# ============================================================
# CONFIGURATION
# ============================================================
$VPS_HOST     = "130.210.14.177"
$VPS_USER     = "ubuntu"
$VPS_SSH_PORT = 22

# GitHub raw file URLs
$GITHUB_RAW_BASE = "https://raw.githubusercontent.com/rohitdahiyaaa/remote-manager/windows-client"
$TUNNEL_SCRIPT_URL  = "$GITHUB_RAW_BASE/reverse-tunnel.ps1"
$INSTALL_SCRIPT_URL = "$GITHUB_RAW_BASE/install-service.ps1"

# Local install directory on the target PC
$INSTALL_DIR = "$env:USERPROFILE\management-client"
$SSH_KEY_PATH = "$env:USERPROFILE\.ssh\id_rsa_tunnel"
# ============================================================

# Colors
function Write-Step { param($msg) Write-Host "`n[$((Get-Variable -Name stepNum -ErrorAction SilentlyContinue).Value)]  $msg" -ForegroundColor Cyan; if (-not (Get-Variable -Name stepNum -Scope Script -ErrorAction SilentlyContinue)) { $script:stepNum = 1 }; $script:stepNum++ }
function Write-OK   { param($msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Fail { param($msg) Write-Host "    [FAIL] $msg" -ForegroundColor Red }
function Write-Info { param($msg) Write-Host "    $msg" -ForegroundColor Gray }

$script:stepNum = 1
$PC_NAME = $DeviceName
$REVERSE_PORT = $Port

Write-Host ""
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host "   Remote Management — Target Device Setup   " -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Device: $PC_NAME | Port: $REVERSE_PORT" -ForegroundColor White
Write-Host ""

# ── Step 1: Check Admin ─────────────────────────────────────
Write-Step "Checking administrator privileges..."

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Fail "This script must be run as Administrator!"
    Write-Host "    Right-click PowerShell -> Run as Administrator" -ForegroundColor Yellow
    exit 1
}
Write-OK "Running as Administrator"

# ── Step 2: Install OpenSSH Server ──────────────────────────
Write-Step "Installing OpenSSH Server..."

$sshCapability = Get-WindowsCapability -Online | Where-Object Name -like "OpenSSH.Server*"
if ($sshCapability.State -eq "Installed") {
    Write-OK "OpenSSH Server already installed"
} else {
    Write-Info "Installing OpenSSH Server (this may take a minute)..."
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    if ($?) {
        Write-OK "OpenSSH Server installed"
    } else {
        Write-Fail "Failed to install OpenSSH Server"
        exit 1
    }
}

# ── Step 3: Start & enable sshd ─────────────────────────────
Write-Step "Starting SSH Server service..."

Start-Service sshd -ErrorAction SilentlyContinue
Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue

$sshdStatus = Get-Service sshd -ErrorAction SilentlyContinue
if ($sshdStatus.Status -eq "Running") {
    Write-OK "SSH Server is running (StartType: Automatic)"
} else {
    Write-Fail "SSH Server failed to start. Status: $($sshdStatus.Status)"
    exit 1
}

# ── Step 4: Create install directory ────────────────────────
Write-Step "Creating install directory..."

if (-not (Test-Path $INSTALL_DIR)) {
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
}
Write-OK "Directory: $INSTALL_DIR"

# ── Step 5: Download scripts from GitHub ────────────────────
Write-Step "Downloading client scripts from GitHub..."

try {
    Write-Info "Downloading reverse-tunnel.ps1..."
    Invoke-WebRequest -Uri $TUNNEL_SCRIPT_URL -OutFile "$INSTALL_DIR\reverse-tunnel.ps1" -UseBasicParsing
    Write-OK "reverse-tunnel.ps1 downloaded"

    Write-Info "Downloading install-service.ps1..."
    Invoke-WebRequest -Uri $INSTALL_SCRIPT_URL -OutFile "$INSTALL_DIR\install-service.ps1" -UseBasicParsing
    Write-OK "install-service.ps1 downloaded"
} catch {
    Write-Fail "Failed to download from GitHub: $_"
    Write-Host ""
    Write-Host "    Make sure the GitHub repo is public and the URLs are correct." -ForegroundColor Yellow
    exit 1
}

# ── Step 6: Configure the tunnel script ─────────────────────
Write-Step "Configuring reverse-tunnel.ps1 with your device settings..."

$tunnelScript = Get-Content "$INSTALL_DIR\reverse-tunnel.ps1" -Raw

# Replace configuration values
$tunnelScript = $tunnelScript -replace '\$VPS_HOST\s*=\s*"[^"]*"',        "`$VPS_HOST        = `"$VPS_HOST`""
$tunnelScript = $tunnelScript -replace '\$VPS_USER\s*=\s*"[^"]*"',        "`$VPS_USER        = `"$VPS_USER`""
$tunnelScript = $tunnelScript -replace '\$VPS_SSH_PORT\s*=\s*\d+',        "`$VPS_SSH_PORT    = $VPS_SSH_PORT"
$tunnelScript = $tunnelScript -replace '\$REVERSE_PORT\s*=\s*\d+',        "`$REVERSE_PORT    = $REVERSE_PORT"
$tunnelScript = $tunnelScript -replace '\$PC_NAME\s*=\s*[^\r\n]+',        "`$PC_NAME         = `"$PC_NAME`""
$tunnelScript = $tunnelScript -replace '\$SSH_KEY_PATH\s*=\s*"[^"]*"',    "`$SSH_KEY_PATH    = `"$SSH_KEY_PATH`""

Set-Content -Path "$INSTALL_DIR\reverse-tunnel.ps1" -Value $tunnelScript
Write-OK "Tunnel configured: VPS=$VPS_HOST, Port=$REVERSE_PORT, Name=$PC_NAME"

# ── Step 7: Save Shared SSH Key ─────────────────────────────
Write-Step "Setting up SSH key authentication..."

$keyDir = Split-Path $SSH_KEY_PATH -Parent
if (-not (Test-Path $keyDir)) {
    New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
}

try {
    $keyBytes = [System.Convert]::FromBase64String($SharedKey)
    [System.IO.File]::WriteAllBytes($SSH_KEY_PATH, $keyBytes)
    icacls $SSH_KEY_PATH /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
    Write-OK "Shared SSH key saved and configured!"
} catch {
    Write-Fail "Failed to decode shared key. Make sure the Base64 string is correct."
    exit 1
}

# ── Step 8: Install as boot service ─────────────────────────
Write-Step "Installing tunnel as Windows boot service..."

& "$INSTALL_DIR\install-service.ps1" -ScriptPath "$INSTALL_DIR\reverse-tunnel.ps1"

Write-OK "Boot service installed"

# ── Step 9: Start tunnel and verify ─────────────────────────
Write-Step "Starting reverse tunnel..."

Write-Info "Testing SSH connection to VPS..."
$result = ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i $SSH_KEY_PATH -p $VPS_SSH_PORT "$VPS_USER@$VPS_HOST" "echo CONNECTION_OK" 2>&1

if ($result -match "CONNECTION_OK") {
    Write-OK "Connection to VPS successful!"
    Start-ScheduledTask -TaskName "ReverseTunnelToVPS" -ErrorAction SilentlyContinue
    Write-OK "Tunnel started!"
} else {
    Write-Fail "Connection test failed. The tunnel will retry automatically on boot."
    Write-Info "Check that the shared key's public key is in the VPS authorized_keys."
}

# ── Step 10: Display summary ────────────────────────────────
Write-Step "Setup complete!"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "   SETUP COMPLETED SUCCESSFULLY!             " -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Device Name:  $PC_NAME" -ForegroundColor White
Write-Host "  Tunnel Port:  $REVERSE_PORT" -ForegroundColor White
Write-Host "  VPS Target:   $VPS_USER@$VPS_HOST" -ForegroundColor White
Write-Host "  Install Dir:  $INSTALL_DIR" -ForegroundColor White
Write-Host "  SSH Key:      $SSH_KEY_PATH" -ForegroundColor White
Write-Host ""
Write-Host "  This device will now auto-connect on every boot." -ForegroundColor Green
Write-Host ""
