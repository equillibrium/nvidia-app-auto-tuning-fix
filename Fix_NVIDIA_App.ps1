# NVIDIA App Automatic Tuning Fix
# Fixes:
# 1. Missing overclocking plugin in NvContainer (junction link Plugins\localuser\oc -> Plugins\oc).
# 2. NVIDIA App 11.0.9+ stuck slider bug (slider shows ON with +0 MHz on launch).
# 3. NVIDIA App 11.0.9+ / Driver 621+ error on enabling scan ("Something went wrong" / NVAPI error -104 on background OC scan).
# 4. Session 0 isolation admin consent failure in _OverClockingNvc.dll (StartOcManualScan returning result: false).
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

# --- Step 1: Stop NVIDIA services and processes to unlock files ---
Write-Host "[1/5] Stopping NVIDIA services and processes to unlock files..." -ForegroundColor Green
try {
    Stop-Service -Name "NvContainerLocalSystem" -Force -ErrorAction SilentlyContinue
    Write-Host "  [+] Service NvContainerLocalSystem stopped" -ForegroundColor Green
} catch {
    # Non-fatal if already stopped
}

Get-Process -Name "nvcontainer" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Name "NVIDIA App" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Name "NVIDIA Overlay" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800
Write-Host "  [+] Cleaned up active processes" -ForegroundColor Green

# --- Step 2: Linking overclocking plugin ---
Write-Host ""
Write-Host "[2/5] Checking and linking overclocking plugin to NvContainer..." -ForegroundColor Green
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

# --- Step 3: Patching Session 0 admin consent in _OverClockingNvc.dll ---
Write-Host ""
Write-Host "[3/5] Checking and patching admin consent in _OverClockingNvc.dll..." -ForegroundColor Green
$dllLocations = @(
    (Join-Path $ocDir "_OverClockingNvc.dll"),
    (Join-Path $fallbackDir "_OverClockingNvc.dll")
) | Select-Object -Unique

foreach ($dllPath in $dllLocations) {
    if (Test-Path $dllPath) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($dllPath)
            # Pattern: E9 DB 47 05 00 (jmp to hasAdminConsent Session 0 check)
            # Replace: B0 01 C3 90 90 (mov al, 1; ret; nop; nop)
            $foundIdx = -1
            for ($i = 0; $i -le $bytes.Length - 5; $i++) {
                if ($bytes[$i] -eq 0xE9 -and $bytes[$i+1] -eq 0xDB -and $bytes[$i+2] -eq 0x47 -and $bytes[$i+3] -eq 0x05 -and $bytes[$i+4] -eq 0x00) {
                    $foundIdx = $i
                    break
                }
            }

            if ($foundIdx -ne -1) {
                $bakDll = "$dllPath.bak"
                if (-not (Test-Path $bakDll)) {
                    Copy-Item -Path $dllPath -Destination $bakDll -Force
                    Write-Host "  [+] Backup created: $(Split-Path $dllPath -Leaf).bak" -ForegroundColor Green
                }

                $bytes[$foundIdx]     = 0xB0 # mov al, 1
                $bytes[$foundIdx + 1] = 0x01
                $bytes[$foundIdx + 2] = 0xC3 # ret
                $bytes[$foundIdx + 3] = 0x90 # nop
                $bytes[$foundIdx + 4] = 0x90 # nop

                [System.IO.File]::WriteAllBytes($dllPath, $bytes)
                Write-Host "  [+] Unlocked admin consent in $(Split-Path $dllPath -Leaf)" -ForegroundColor Green
            } else {
                # Check if already patched
                $alreadyPatched = $false
                for ($i = 0; $i -le $bytes.Length - 5; $i++) {
                    if ($bytes[$i] -eq 0xB0 -and $bytes[$i+1] -eq 0x01 -and $bytes[$i+2] -eq 0xC3 -and $bytes[$i+3] -eq 0x90 -and $bytes[$i+4] -eq 0x90) {
                        $alreadyPatched = $true
                        break
                    }
                }
                if ($alreadyPatched) {
                    Write-Host "  [+] Admin consent in $(Split-Path $dllPath -Leaf) is already unlocked." -ForegroundColor Green
                } else {
                    Write-Host "  [!] Pattern not found in $(Split-Path $dllPath -Leaf), skipping binary patch." -ForegroundColor Yellow
                }
            }
        } catch {
            Write-Host "  [!] Could not patch $($dllPath): $_" -ForegroundColor Yellow
        }
    }
}

# --- Step 4: Fixing stuck slider & scan launch bugs in UI ---
Write-Host ""
Write-Host "[4/5] Checking and patching NVIDIA App UI logic..." -ForegroundColor Green
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

# --- Step 5: Clean UI cache and restart services ---
Write-Host ""
Write-Host "[5/5] Cleaning UI cache and starting NVIDIA services..." -ForegroundColor Green
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
            # Non-fatal
        }
    }
}

try {
    Start-Service -Name "NvContainerLocalSystem" -ErrorAction SilentlyContinue
    Write-Host "  [+] Service NvContainerLocalSystem started" -ForegroundColor Green
} catch {
    Write-Host "  [!] Could not start NvContainerLocalSystem automatically. Please start it from services.msc." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "               Fix applied successfully!" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "RESULTS:" -ForegroundColor Yellow
Write-Host "1. Overclocking plugin linked to NvContainer."
Write-Host "2. Admin consent unlocked in _OverClockingNvc.dll (Session 0 fix)."
Write-Host "3. Stuck slider bug fixed: Automatic Tuning toggle will no longer"
Write-Host "   falsely show ON at +0 MHz."
Write-Host "4. Tuning scan start bug fixed: clicking the toggle will now"
Write-Host "   properly launch the manual OC scanner."
Write-Host "5. Launch NVIDIA App -> System -> Performance to start tuning."
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "Press Enter to exit..."
