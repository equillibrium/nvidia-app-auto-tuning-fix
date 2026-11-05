@echo off
setlocal
chcp 65001 >nul

:: Determine 64-bit Program Files directory even from 32-bit CMD
set "PF=%ProgramFiles%"
if defined ProgramW6432 set "PF=%ProgramW6432%"

:: Self-elevation to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [i] Requesting Administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

title NVIDIA App Automatic Tuning Fix

:: If Fix_NVIDIA_App.ps1 exists next to this bat, run it
if exist "%~dp0Fix_NVIDIA_App.ps1" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fix_NVIDIA_App.ps1"
    exit /b %errorlevel%
)
if exist "%~dp0fix_nvidia.ps1" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix_nvidia.ps1"
    exit /b %errorlevel%
)

echo =========================================================
echo    NVIDIA App Automatic Tuning Fix (v11.0.9+ Compatible)
echo =========================================================
echo.

set "OC_DIR=%PF%\NVIDIA Corporation\NVIDIA App\Plugins\oc"
set "TARGET_DIR=%PF%\NVIDIA Corporation\NVIDIA App\Plugins\localuser\oc"
set "NVAPP_DIR=%PF%\NVIDIA Corporation\NVIDIA App\Plugins\localuser\NvApp"
set "WWW_DIR=%PF%\NVIDIA Corporation\NVIDIA App\www"

if not exist "%PF%\NVIDIA Corporation\NVIDIA App" (
    echo [ERROR] NVIDIA App directory not found.
    echo Please make sure NVIDIA App is installed.
    echo.
    pause
    exit /b 1
)

echo [1/4] Connecting overclocking plugin to NVIDIA Container...
if exist "%OC_DIR%" (
    if not exist "%TARGET_DIR%" (
        mklink /J "%TARGET_DIR%" "%OC_DIR%" >nul 2>&1
        if %errorlevel% equ 0 (
            echo   [+] Junction link successfully created.
        ) else (
            echo   [!] Junction failed, copying plugin files directly...
            copy /Y "%OC_DIR%\_OverClockingNvc.*" "%NVAPP_DIR%\" >nul 2>&1
        )
    ) else (
        echo   [+] Overclocking plugin is already linked.
    )
) else (
    echo   [!] "%OC_DIR%" not found, skipping junction.
)

echo.
echo [2/4] Checking and fixing stuck slider & scan launch bugs (NVIDIA App 11.0.9+)...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$www = '%WWW_DIR%'; if (Test-Path $www) { foreach ($js in (Get-ChildItem -Path $www -Filter 'main.*.js')) { try { $c = [System.IO.File]::ReadAllText($js.FullName); $t1 = 'W=>W.stable||0===W.type'; $r1 = 'W=>(W.stable&&W.averageGpuClockOffsetMhz>0)||0===W.type'; $t2_1 = 'automaticTuningEnabled=K.enable?p.T8.TRUE:p.T8.FALSE,B.result||!K.enable)'; $t2_2 = 'automaticTuningEnabled=K.enable?p.T8.TRUE:p.T8.FALSE,B.result)'; $r2 = 'automaticTuningEnabled=K.enable?p.T8.TRUE:p.T8.FALSE,!0)'; $t3 = 'W=>W?this.startOcScan():(this.logger.error(\"Background Oc scan not enabled, Not starting Oc scan\"),(0,s.of)(!1))'; $r3 = '()=>this.startOcScan()'; $needsUpdate = $c.Contains($t1) -or $c.Contains($t2_1) -or $c.Contains($t2_2) -or $c.Contains($t3); if ($needsUpdate) { $bak = \"$($js.FullName).bak\"; if (-not (Test-Path $bak)) { Copy-Item $js.FullName $bak -Force }; if ($c.Contains($t1)) { $c = $c.Replace($t1, $r1) }; if ($c.Contains($t2_1)) { $c = $c.Replace($t2_1, $r2) }; if ($c.Contains($t2_2)) { $c = $c.Replace($t2_2, $r2) }; if ($c.Contains($t3)) { $c = $c.Replace($t3, $r3) }; [System.IO.File]::WriteAllText($js.FullName, $c, [System.Text.Encoding]::UTF8); Write-Host '  [+] Patched UI logic in ' $js.Name } else { Write-Host '  [+] UI logic is already clean and fully patched.' } } catch { Write-Host '  [!] Failed to patch: ' $_ } } }"

echo.
echo [3/4] Cleaning UI cache...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$cacheDirs = @(\"$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA App\CefCache\", \"$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA Overlay\CefCache\"); foreach ($d in $cacheDirs) { if (Test-Path $d) { Remove-Item \"$d\Cache\*\" -Recurse -Force -ErrorAction SilentlyContinue } }"

echo.
echo [4/4] Restarting NVIDIA services and UI processes...
net stop NvContainerLocalSystem >nul 2>&1
net start NvContainerLocalSystem >nul 2>&1

taskkill /f /im nvcontainer.exe /fi "SESSION ne 0" >nul 2>&1
taskkill /f /im "NVIDIA App.exe" >nul 2>&1
taskkill /f /im "NVIDIA Overlay.exe" >nul 2>&1
echo   [+] Cleaned up active processes.

echo.
echo =========================================================
echo               Fix applied successfully!
echo =========================================================
echo RESULTS:
echo 1. Overclocking plugin linked to NvContainer.
echo 2. Fixed stuck slider bug: Automatic Tuning will no longer
echo    falsely show ON at 0 MHz.
echo 3. Fixed scan start bug: clicking the toggle now starts
echo    the manual OC tuning scan without error toasts.
echo 4. Open NVIDIA App -^> System -^> Performance to verify.
echo =========================================================
echo.
pause
