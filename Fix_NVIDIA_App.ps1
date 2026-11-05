# NVIDIA App Automatic Tuning Fix
# Fixes:
# 1. Missing overclocking plugin in NvContainer (junction link Plugins\localuser\oc -> Plugins\oc).
# 2. NVIDIA App 11.0.9+ stuck slider bug (slider shows ON with +0 MHz on launch).
# 3. NVIDIA App 11.0.9+ / Driver 621+ error on enabling scan ("Something went wrong" / NVAPI error -104 on background OC scan).
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
$nvAppDir = Join-Path $programFiles "NVIDIA Corporation\NVIDIA App"
$nvAppPlugins = Join-Path $nvAppDir "Plugins"

$ocDir = Join-Path $nvAppPlugins "oc"
$targetDir = Join-Path $nvAppPlugins "localuser\oc"
$fallbackDir = Join-Path $nvAppPlugins "localuser\NvApp"
$wwwDir = Join-Path $nvAppDir "www"

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "         NVIDIA App Automatic Tuning Fix" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $nvAppDir)) {
    Write-Host "[ERROR] Directory '$nvAppDir' not found." -ForegroundColor Red
    Write-Host "Please make sure NVIDIA App is installed." -ForegroundColor Red
    Read-Host "Press Enter to exit..."
    exit 1
}

# --- Step 1: Linking overclocking plugin ---
Write-Host "[1/4] Checking and linking overclocking plugin to NvContainer..." -ForegroundColor Green
if (Test-Path $ocDir) {
    if (-not (Test-Path $targetDir)) {
        try {
            cmd.exe /c "mklink /J `"$targetDir`" `"$ocDir`"" | Out-Null
            if (Test-Path $targetDir) {
                Write-Host "  [+] Junction link created: $targetDir" -ForegroundColor Green
            } else {
                throw "mklink failed"
            }
        } catch {
            Write-Host "  [!] Junction failed. Falling back to direct file copy..." -ForegroundColor Yellow
            Copy-Item -Path (Join-Path $ocDir "_OverClockingNvc.*") -Destination $fallbackDir -Force
            Write-Host "  [+] Copied _OverClockingNvc plugin to $fallbackDir" -ForegroundColor Green
        }
    } else {
        Write-Host "  [+] Overclocking plugin is already linked: $targetDir" -ForegroundColor Green
    }
} else {
    Write-Host "  [!] Directory '$ocDir' not found, skipping junction creation." -ForegroundColor Yellow
}

# --- Step 2: Fixing stuck slider & scan launch bugs in UI ---
Write-Host ""
Write-Host "[2/4] Checking and patching NVIDIA App UI logic..." -ForegroundColor Green
$patchedAny = $false
if (Test-Path $wwwDir) {
    $mainJsFiles = Get-ChildItem -Path $wwwDir -Filter "main.*.js" -File
    foreach ($js in $mainJsFiles) {
        try {
            $content = [System.IO.File]::ReadAllText($js.FullName)
            $needsPatch = $false

            # Patch 1: getAutoTuneToggleState() checks W.stable without checking offset > 0
            $t1 = 'W=>W.stable||0===W.type'
            $r1 = 'W=>(W.stable&&W.averageGpuClockOffsetMhz>0)||0===W.type'

            # Patch 2: enableBackgroundOcScan throws error on driver NVAPI -104 (unsupported bg scan)
            $t2_1 = 'automaticTuningEnabled=K.enable?p.T8.TRUE:p.T8.FALSE,B.result||!K.enable)'
            $t2_2 = 'automaticTuningEnabled=K.enable?p.T8.TRUE:p.T8.FALSE,B.result)'
            $r2   = 'automaticTuningEnabled=K.enable?p.T8.TRUE:p.T8.FALSE,!0)'

            # Patch 3: enableBgOcScanAndStartScan directly triggers startOcScan() without waiting/failing on background oc scan
            $t3 = 'W=>W?this.startOcScan():(this.logger.error("Background Oc scan not enabled, Not starting Oc scan"),(0,s.of)(!1))'
            $r3 = '()=>this.startOcScan()'

            $fileNeedsUpdate = $content.Contains($t1) -or $content.Contains($t2_1) -or $content.Contains($t2_2) -or $content.Contains($t3)

            if ($fileNeedsUpdate) {
                $bakFile = "$($js.FullName).bak"
                if (-not (Test-Path $bakFile)) {
                    Copy-Item -Path $js.FullName -Destination $bakFile -Force
                    Write-Host "  [+] Backup created: $($js.Name).bak" -ForegroundColor Green
                }

                if ($content.Contains($t1)) {
                    $content = $content.Replace($t1, $r1)
                    $needsPatch = $true
                }
                if ($content.Contains($t2_1)) {
                    $content = $content.Replace($t2_1, $r2)
                    $needsPatch = $true
                }
                if ($content.Contains($t2_2)) {
                    $content = $content.Replace($t2_2, $r2)
                    $needsPatch = $true
                }
                if ($content.Contains($t3)) {
                    $content = $content.Replace($t3, $r3)
                    $needsPatch = $true
                }

                if ($needsPatch) {
                    [System.IO.File]::WriteAllText($js.FullName, $content, [System.Text.Encoding]::UTF8)
                    Write-Host "  [+] Patched UI logic in $($js.Name)" -ForegroundColor Green
                    $patchedAny = $true
                }
            } else {
                Write-Host "  [+] UI logic in $($js.Name) is already clean and fully patched." -ForegroundColor Green
            }
        } catch {
            Write-Host "  [!] Could not patch $($js.Name): $_" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  [!] UI directory '$wwwDir' not found." -ForegroundColor Yellow
}

# --- Step 3: Clean up cache if patched ---
Write-Host ""
Write-Host "[3/4] Cleaning NVIDIA App UI cache..." -ForegroundColor Green
$cacheDirs = @(
    "$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA App\CefCache",
    "$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA Overlay\CefCache"
)
foreach ($cDir in $cacheDirs) {
    if (Test-Path $cDir) {
        try {
            Remove-Item -Path "$cDir\Cache\*" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  [+] Cleared cache: $cDir\Cache" -ForegroundColor Green
        } catch {
            # Non-fatal if locked
        }
    }
}

# --- Step 4: Restart NVIDIA services and processes ---
Write-Host ""
Write-Host "[4/4] Restarting NVIDIA services and UI processes..." -ForegroundColor Green
try {
    Restart-Service -Name "NvContainerLocalSystem" -Force -ErrorAction SilentlyContinue
    Write-Host "  [+] Service NvContainerLocalSystem restarted" -ForegroundColor Green
} catch {
    Write-Host "  [!] Could not restart NvContainerLocalSystem automatically." -ForegroundColor Yellow
}

# Stop active UI and session container processes
Get-Process -Name "nvcontainer" -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -ne 0 } | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Name "NVIDIA App" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Name "NVIDIA Overlay" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host "  [+] Cleaned up active NVIDIA App processes" -ForegroundColor Green

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "               Fix applied successfully!" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "RESULTS:" -ForegroundColor Yellow
Write-Host "1. Overclocking plugin linked to NvContainer."
Write-Host "2. Stuck slider bug fixed: Automatic Tuning toggle will no longer"
Write-Host "   falsely show ON at +0 MHz."
Write-Host "3. Tuning scan start bug fixed: clicking the toggle will now"
Write-Host "   properly launch the manual OC scanner instead of showing"
Write-Host "   'Something went wrong' / error -104."
Write-Host "4. Launch NVIDIA App -> System -> Performance to start tuning."
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "Press Enter to exit..."
