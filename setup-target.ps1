<#
.SYNOPSIS
    One-click target device setup for Remote Management System.
    Run this script on any Windows PC you want to manage remotely.

.DESCRIPTION
    This script:
    1. Installs & starts OpenSSH Server
    2. Downloads client files from your GitHub repo
    3. Generates an SSH keypair for the tunnel
    4. Asks for a unique device name and port
    5. Configures and starts the reverse tunnel
    6. Installs the tunnel as a boot service
    7. Outputs the public key to add to the VPS

.NOTES
    Run as Administrator on the target PC.
    Usage: powershell -ExecutionPolicy Bypass -File setup-target.ps1
#>

# ============================================================
# CONFIGURATION — EDIT THESE BEFORE UPLOADING TO GITHUB
# ============================================================
$VPS_HOST     = "130.210.14.177"
$VPS_USER     = "ubuntu"
$VPS_SSH_PORT = 22

# GitHub raw file URLs (update after uploading to your repo)
$GITHUB_RAW_BASE = "https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/windows-client"
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

Write-Host ""
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host "   Remote Management — Target Device Setup   " -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host ""

# ── Step 1: Check Admin ─────────────────────────────────────
Write-Step "Checking administrator privileges..."

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Fail "This script must be run as Administrator!"
    Write-Host "    Right-click PowerShell -> Run as Administrator" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
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
        Read-Host "Press Enter to exit"
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
    Read-Host "Press Enter to exit"
    exit 1
}

# ── Step 4: Ask for device info ─────────────────────────────
Write-Step "Configuring device identity..."

$defaultName = $env:COMPUTERNAME
$PC_NAME = Read-Host "    Enter a name for this device (default: $defaultName)"
if ([string]::IsNullOrWhiteSpace($PC_NAME)) { $PC_NAME = $defaultName }

$REVERSE_PORT = Read-Host "    Enter the unique port number for this device (e.g. 2201, 2202)"
if ([string]::IsNullOrWhiteSpace($REVERSE_PORT)) {
    Write-Fail "Port number is required!"
    Read-Host "Press Enter to exit"
    exit 1
}

Write-OK "Device: $PC_NAME | Port: $REVERSE_PORT"

# ── Step 5: Create install directory ────────────────────────
Write-Step "Creating install directory..."

if (-not (Test-Path $INSTALL_DIR)) {
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
}
Write-OK "Directory: $INSTALL_DIR"

# ── Step 6: Download scripts from GitHub ────────────────────
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
    Write-Host "    Make sure you have uploaded the files to your GitHub repo" -ForegroundColor Yellow
    Write-Host "    and updated the GITHUB_RAW_BASE URL at the top of this script." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}

# ── Step 7: Configure the tunnel script ─────────────────────
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

# ── Step 8: Generate SSH Key ────────────────────────────────
Write-Step "Setting up SSH key authentication..."

$keyDir = Split-Path $SSH_KEY_PATH -Parent
if (-not (Test-Path $keyDir)) {
    New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
}

if (Test-Path $SSH_KEY_PATH) {
    Write-OK "SSH key already exists at $SSH_KEY_PATH"
} else {
    Write-Info "Generating new SSH keypair..."
    ssh-keygen -t ed25519 -f $SSH_KEY_PATH -N '""' -C "tunnel-$PC_NAME" 2>&1 | Out-Null
    if (Test-Path $SSH_KEY_PATH) {
        Write-OK "SSH keypair generated"
    } else {
        Write-Fail "Failed to generate SSH key"
        Read-Host "Press Enter to exit"
        exit 1
    }
}

$publicKey = Get-Content "$SSH_KEY_PATH.pub"

# ── Step 9: Install as boot service ─────────────────────────
Write-Step "Installing tunnel as Windows boot service..."

& "$INSTALL_DIR\install-service.ps1" -ScriptPath "$INSTALL_DIR\reverse-tunnel.ps1"

Write-OK "Boot service installed"

# ── Step 10: Display summary & public key ────────────────────
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
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host "   ACTION REQUIRED: Add this public key      " -ForegroundColor Yellow
Write-Host "   to your VPS authorized_keys file           " -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  $publicKey" -ForegroundColor Cyan
Write-Host ""
Write-Host "  On your VPS run:" -ForegroundColor Gray
Write-Host "  echo '$publicKey' >> ~/.ssh/authorized_keys" -ForegroundColor White
Write-Host ""
Write-Host "=============================================" -ForegroundColor Yellow

# Copy public key to clipboard
$publicKey | Set-Clipboard
Write-Host "  Public key has been copied to your clipboard!" -ForegroundColor Green
Write-Host ""

# ── Step 11: Test connection ─────────────────────────────────
$testNow = Read-Host "Do you want to test the VPS connection now? (y/n)"
if ($testNow -eq "y") {
    Write-Host ""
    Write-Info "Testing SSH connection to VPS..."
    Write-Info "(This will fail if you haven't added the public key to VPS yet)"
    Write-Host ""

    $result = ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i $SSH_KEY_PATH -p $VPS_SSH_PORT "$VPS_USER@$VPS_HOST" "echo CONNECTION_OK" 2>&1

    if ($result -match "CONNECTION_OK") {
        Write-OK "Connection to VPS successful!"
        Write-Host ""

        # Start the tunnel now
        $startNow = Read-Host "Start the reverse tunnel now? (y/n)"
        if ($startNow -eq "y") {
            Start-ScheduledTask -TaskName "ReverseTunnelToVPS"
            Write-OK "Tunnel started! Your device should now appear ONLINE in the VPS panel."
        }
    } else {
        Write-Fail "Connection failed. Make sure the public key is added to the VPS."
        Write-Info "After adding the key, start the tunnel with:"
        Write-Host "  Start-ScheduledTask -TaskName 'ReverseTunnelToVPS'" -ForegroundColor White
    }
}

Write-Host ""
Write-Host "Done! You can close this window." -ForegroundColor Green
Read-Host "Press Enter to exit"
