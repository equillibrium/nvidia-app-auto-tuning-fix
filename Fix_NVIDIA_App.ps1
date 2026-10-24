# NVIDIA App Automatic Tuning Fix
# Fixes the issue where Automatic Tuning immediately resets or fails to start.
# Requires Administrator privileges.

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[*] Requesting Administrator privileges..." -ForegroundColor Yellow
    try {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    } catch {
        Write-Error "Failed to elevate privileges: $_"
    }
    exit
}

$ErrorActionPreference = "Stop"

# Resolve 64-bit Program Files directory
$programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$nvAppBase = Join-Path $programFiles "NVIDIA Corporation\NVIDIA App\Plugins"

$ocDir = Join-Path $nvAppBase "oc"
$targetDir = Join-Path $nvAppBase "localuser\oc"
$fallbackDir = Join-Path $nvAppBase "localuser\NvApp"

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "         NVIDIA App Automatic Tuning Fix" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $ocDir)) {
    Write-Host "[ERROR] Directory '$ocDir' not found." -ForegroundColor Red
    Write-Host "Please make sure NVIDIA App is installed." -ForegroundColor Red
    Read-Host "Press Enter to exit..."
    exit 1
}

Write-Host "[1/3] Linking overclocking plugin to NVIDIA Container..." -ForegroundColor Green
if (-not (Test-Path $targetDir)) {
    try {
        # Create directory junction
        cmd.exe /c "mklink /J `"$targetDir`" `"$ocDir`"" | Out-Null
        if (Test-Path $targetDir) {
            Write-Host "  [+] Junction link created successfully: $targetDir" -ForegroundColor Green
        } else {
            throw "mklink failed"
        }
    } catch {
        Write-Host "  [!] Junction creation failed. Falling back to direct file copy..." -ForegroundColor Yellow
        Copy-Item -Path (Join-Path $ocDir "_OverClockingNvc.*") -Destination $fallbackDir -Force
        Write-Host "  [+] Copied _OverClockingNvc plugin to $fallbackDir" -ForegroundColor Green
    }
} else {
    Write-Host "  [+] Overclocking plugin is already linked: $targetDir" -ForegroundColor Green
}

Write-Host ""
Write-Host "[2/3] Restarting NVIDIA services..." -ForegroundColor Green
try {
    Restart-Service -Name "NvContainerLocalSystem" -Force -ErrorAction SilentlyContinue
    Write-Host "  [+] Service NvContainerLocalSystem restarted" -ForegroundColor Green
} catch {
    Write-Host "  [!] Could not restart NvContainerLocalSystem service automatically." -ForegroundColor Yellow
}

# Kill user-session nvcontainer and NVIDIA App UI
Get-Process -Name "nvcontainer" -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -ne 0 } | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Name "NVIDIA App" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host "  [+] Cleaned up active NVIDIA App processes" -ForegroundColor Green

Write-Host ""
Write-Host "[3/3] Fix applied successfully!" -ForegroundColor Cyan
Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host "1. Close GPU-intensive applications (games, 3D apps, Discord hardware accel)."
Write-Host "2. Launch NVIDIA App."
Write-Host "3. Go to System -> Performance."
Write-Host "4. Enable 'Automatic Tuning'."
Write-Host "   (Scanning takes approximately 10-20 minutes)"
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "Press Enter to exit..."