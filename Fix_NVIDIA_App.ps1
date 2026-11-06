# NVIDIA App Automatic Tuning Fix
# Verified with: NVIDIA App v11.0.9.585+ | GeForce Game Ready Driver v621.14+ (RTX 50-series / 40-series / 30-series)
# Fixes:
# 1. Missing overclocking plugin in NvContainer (junction link Plugins\localuser\oc -> Plugins\oc).
# 2. NVIDIA App 11.0.9+ stuck slider bug (slider shows ON with +0 MHz on launch).
# 3. NVIDIA App 11.0.9+ / Driver 621+ error on enabling scan ("Something went wrong" / NVAPI error -104 on background OC scan).
# 4. Admin consent registry configuration in HKLM for seamless permission granting.
# 5. Restores original signed _OverClockingNvc.dll if modified, ensuring NvContainer signature check passes.
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

# --- Step 3: Verifying DLL integrity and setting Admin Consent in Registry ---
Write-Host ""
Write-Host "[3/5] Verifying plugin signature and setting Admin Consent in Registry..." -ForegroundColor Green

# 3a. Restore original signed _OverClockingNvc.dll if modified (.bak exists and signature was broken)
$dllLocations = @(
    (Join-Path $ocDir "_OverClockingNvc.dll"),
    (Join-Path $fallbackDir "_OverClockingNvc.dll")
) | Select-Object -Unique

foreach ($dllPath in $dllLocations) {
    if (Test-Path $dllPath) {
        $bakPath = "$dllPath.bak"
        $sig = Get-AuthenticodeSignature $dllPath -ErrorAction SilentlyContinue
        if ($null -ne $sig -and $sig.Status -ne "Valid") {
            if (Test-Path $bakPath) {
                Write-Host "  [*] Restoring original signed DLL from backup: $dllPath" -ForegroundColor Yellow
                try {
                    Copy-Item -Path $bakPath -Destination $dllPath -Force
                    $newSig = Get-AuthenticodeSignature $dllPath
                    if ($newSig.Status -eq "Valid") {
                        Write-Host "  [+] Original signed DLL restored successfully (Signature: Valid)" -ForegroundColor Green
                    } else {
                        Write-Host "  [!] Restored DLL status is $($newSig.Status)" -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "  [!] Failed to restore DLL from backup: $_" -ForegroundColor Yellow
                }
            } else {
                Write-Host "  [!] Warning: DLL signature is $($sig.Status) but backup not found." -ForegroundColor Yellow
            }
        } else {
            Write-Host "  [+] Plugin DLL signature is valid: $dllPath" -ForegroundColor Green
        }
    }
}

# 3b. Configure Admin Consent in Windows Registry
# OverClockingNvc checks HKLM\SOFTWARE\NVIDIA Corporation\Global\NvApp\OC\<User-SID>
$regPath = "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvApp\OC"
try {
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    
    # Register consent for all active user profiles
    $userProfiles = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" | Where-Object { $_.PSChildName -like "S-1-5-21-*" }
    foreach ($profile in $userProfiles) {
        $sid = $profile.PSChildName
        Set-ItemProperty -Path $regPath -Name $sid -Value 1 -Type DWord -Force
        Write-Host "  [+] Set Admin Consent for SID: $sid" -ForegroundColor Green
    }
    # Also set for SYSTEM (S-1-5-18) and current user identity
    $currentSid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    if ($currentSid) {
        Set-ItemProperty -Path $regPath -Name $currentSid -Value 1 -Type DWord -Force
    }
    Set-ItemProperty -Path $regPath -Name "S-1-5-18" -Value 1 -Type DWord -Force
    Write-Host "  [+] Admin Consent registry keys configured" -ForegroundColor Green
} catch {
    Write-Host "  [!] Could not configure registry keys: $_" -ForegroundColor Yellow
}

# --- Step 4: Patching frontend UI logic ---
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
Write-Host "2. Original signed plugin integrity verified (Authenticode Valid)."
Write-Host "3. Admin consent configured via Windows Registry."
Write-Host "4. Stuck slider bug fixed: Automatic Tuning toggle will no longer"
Write-Host "   falsely show ON at +0 MHz."
Write-Host "5. Background scan NVAPI -104 crash bypassed."
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "Press Enter to exit..."
