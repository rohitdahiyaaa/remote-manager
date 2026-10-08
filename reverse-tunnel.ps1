<#
.SYNOPSIS
    Persistent Reverse SSH Tunnel Client for Windows.
    Creates and maintains a reverse SSH tunnel to the VPS jump host.

.DESCRIPTION
    - Establishes reverse SSH tunnel to Oracle Cloud VPS
    - Auto-reconnects on failure with exponential backoff
    - Sends keepalive packets to detect dead connections
    - Logs all activity for troubleshooting

.NOTES
    Configure the variables below before running.
#>

# ============================================================
# CONFIGURATION - EDIT THESE VALUES
# ============================================================
$VPS_HOST        = "130.210.14.177"         # VPS public IP
$VPS_USER        = "ubuntu"                 # SSH user on VPS
$VPS_SSH_PORT    = 22                       # VPS SSH port
$REVERSE_PORT    = 2201                     # Port on VPS that maps back to this PC
$LOCAL_SSH_PORT  = 22                       # Local SSH/OpenSSH port on this Windows PC
$PC_NAME         = $env:COMPUTERNAME        # Friendly name for this PC
$SSH_KEY_PATH    = "$env:USERPROFILE\.ssh\id_rsa_tunnel"  # Path to SSH private key

# Reconnection settings
$INITIAL_RETRY_DELAY  = 5       # seconds
$MAX_RETRY_DELAY      = 300     # 5 minutes max backoff
$BACKOFF_MULTIPLIER   = 2

# Keepalive settings (SSH level)
$SERVER_ALIVE_INTERVAL  = 15    # Send keepalive every 15 seconds
$SERVER_ALIVE_COUNT_MAX = 3     # Disconnect after 3 missed keepalives (45s)

# Logging
$LOG_DIR  = "$env:USERPROFILE\.ssh\tunnel-logs"
$LOG_FILE = "$LOG_DIR\tunnel-$(Get-Date -Format 'yyyy-MM-dd').log"

# ============================================================
# FUNCTIONS
# ============================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    
    if (-not (Test-Path $LOG_DIR)) {
        New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
    }
    
    # Rotate log file daily
    $script:LOG_FILE = "$LOG_DIR\tunnel-$(Get-Date -Format 'yyyy-MM-dd').log"
    
    Add-Content -Path $LOG_FILE -Value $entry
    Write-Host $entry
}

function Test-SSHKeyExists {
    if (-not (Test-Path $SSH_KEY_PATH)) {
        Write-Log "SSH key not found at $SSH_KEY_PATH" "ERROR"
        Write-Log "Generating new SSH keypair..." "INFO"
        
        $keyDir = Split-Path $SSH_KEY_PATH -Parent
        if (-not (Test-Path $keyDir)) {
            New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
        }
        
        ssh-keygen -t ed25519 -f $SSH_KEY_PATH -N '""' -C "tunnel-$PC_NAME"
        
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Failed to generate SSH key" "ERROR"
            return $false
        }
        
        Write-Log "SSH key generated. Public key:" "INFO"
        $pubKey = Get-Content "$SSH_KEY_PATH.pub"
        Write-Log $pubKey "INFO"
        Write-Log "" "IMPORTANT"
        Write-Log "=== ACTION REQUIRED ===" "IMPORTANT"
        Write-Log "Add the above public key to $VPS_USER@$VPS_HOST:~/.ssh/authorized_keys" "IMPORTANT"
        Write-Log "Run: ssh-copy-id -i $SSH_KEY_PATH.pub $VPS_USER@$VPS_HOST" "IMPORTANT"
        Write-Log "Or manually paste it on the VPS." "IMPORTANT"
        Write-Log "=== THEN RE-RUN THIS SCRIPT ===" "IMPORTANT"
        return $false
    }
    return $true
}

function Test-OpenSSHClient {
    $sshPath = Get-Command ssh -ErrorAction SilentlyContinue
    if (-not $sshPath) {
        Write-Log "OpenSSH client not found. Install it via:" "ERROR"
        Write-Log "  Settings > Apps > Optional Features > OpenSSH Client" "ERROR"
        return $false
    }
    Write-Log "OpenSSH client found: $($sshPath.Source)" "INFO"
    return $true
}

function Test-VPSConnectivity {
    Write-Log "Testing VPS connectivity..." "INFO"
    $result = ssh -o ConnectTimeout=10 `
                  -o BatchMode=yes `
                  -o StrictHostKeyChecking=accept-new `
                  -i $SSH_KEY_PATH `
                  -p $VPS_SSH_PORT `
                  "$VPS_USER@$VPS_HOST" "echo CONNECTION_OK" 2>&1
    
    if ($result -match "CONNECTION_OK") {
        Write-Log "VPS connectivity OK" "INFO"
        return $true
    } else {
        Write-Log "VPS connectivity failed: $result" "ERROR"
        return $false
    }
}

function Register-PCOnVPS {
    Write-Log "Registering this PC ($PC_NAME) on VPS with port $REVERSE_PORT..." "INFO"
    
    # Create/update the PC registry entry on VPS
    $regCmd = @"
mkdir -p ~/management/registry && echo '{"name":"$PC_NAME","port":$REVERSE_PORT,"os":"Windows","last_seen":"$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')"}' > ~/management/registry/${PC_NAME}.json
"@
    
    ssh -o ConnectTimeout=10 `
        -o BatchMode=yes `
        -i $SSH_KEY_PATH `
        -p $VPS_SSH_PORT `
        "$VPS_USER@$VPS_HOST" $regCmd 2>&1 | Out-Null
}

function Start-ReverseTunnel {
    Write-Log "Starting reverse SSH tunnel: VPS:$REVERSE_PORT -> localhost:$LOCAL_SSH_PORT" "INFO"
    
    # Register this PC on the VPS
    Register-PCOnVPS
    
    # Build the SSH command
    # -N = no remote command
    # -T = no pseudo-terminal
    # -R = reverse tunnel
    # ExitOnForwardFailure = fail immediately if port bind fails (port already in use)
    # ServerAliveInterval/CountMax = keepalive to detect dead connections
    $sshArgs = @(
        "-N", "-T",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=$SERVER_ALIVE_INTERVAL",
        "-o", "ServerAliveCountMax=$SERVER_ALIVE_COUNT_MAX",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "BatchMode=yes",
        "-o", "TCPKeepAlive=yes",
        "-o", "Compression=yes",
        "-i", $SSH_KEY_PATH,
        "-p", $VPS_SSH_PORT,
        "-R", "${REVERSE_PORT}:localhost:${LOCAL_SSH_PORT}",
        "$VPS_USER@$VPS_HOST"
    )
    
    Write-Log "SSH args: ssh $($sshArgs -join ' ')" "DEBUG"
    
    $process = Start-Process -FilePath "ssh" `
                             -ArgumentList $sshArgs `
                             -NoNewWindow `
                             -PassThru `
                             -RedirectStandardError "$LOG_DIR\ssh-stderr.log"
    
    return $process
}

function Start-TunnelLoop {
    $retryDelay = $INITIAL_RETRY_DELAY
    $consecutiveFailures = 0
    
    Write-Log "========================================" "INFO"
    Write-Log "Reverse Tunnel Service Starting" "INFO"
    Write-Log "PC Name:      $PC_NAME" "INFO"
    Write-Log "VPS:          $VPS_USER@$VPS_HOST:$VPS_SSH_PORT" "INFO"
    Write-Log "Reverse Port: $REVERSE_PORT -> localhost:$LOCAL_SSH_PORT" "INFO"
    Write-Log "SSH Key:      $SSH_KEY_PATH" "INFO"
    Write-Log "========================================" "INFO"
    
    while ($true) {
        # Start the tunnel
        $process = Start-ReverseTunnel
        
        if ($null -eq $process) {
            Write-Log "Failed to start SSH process" "ERROR"
        } else {
            Write-Log "SSH tunnel process started (PID: $($process.Id))" "INFO"
            
            # Reset backoff on successful connection
            $retryDelay = $INITIAL_RETRY_DELAY
            $consecutiveFailures = 0
            
            # Wait for process to exit (meaning tunnel dropped)
            $process.WaitForExit()
            $exitCode = $process.ExitCode
            
            Write-Log "SSH tunnel exited with code: $exitCode" "WARN"
            
            # Log stderr if available
            if (Test-Path "$LOG_DIR\ssh-stderr.log") {
                $stderr = Get-Content "$LOG_DIR\ssh-stderr.log" -Raw
                if ($stderr) {
                    Write-Log "SSH stderr: $stderr" "WARN"
                }
            }
        }
        
        $consecutiveFailures++
        
        # Exponential backoff
        if ($consecutiveFailures -gt 1) {
            $retryDelay = [Math]::Min($retryDelay * $BACKOFF_MULTIPLIER, $MAX_RETRY_DELAY)
        }
        
        Write-Log "Reconnecting in $retryDelay seconds (attempt #$consecutiveFailures)..." "INFO"
        Start-Sleep -Seconds $retryDelay
    }
}

# ============================================================
# MAIN
# ============================================================

# Pre-flight checks
if (-not (Test-OpenSSHClient)) { exit 1 }
if (-not (Test-SSHKeyExists))  { exit 1 }

# Optional: test connectivity first
if ($args -contains "--test") {
    if (Test-VPSConnectivity) {
        Write-Log "All checks passed!" "INFO"
    } else {
        Write-Log "Connectivity test failed" "ERROR"
        exit 1
    }
    exit 0
}

# Run the persistent tunnel loop
Start-TunnelLoop
