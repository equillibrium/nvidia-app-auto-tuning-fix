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

echo =========================================================
echo    NVIDIA App Automatic Tuning Fix
echo =========================================================
echo.

set "OC_DIR=%PF%\NVIDIA Corporation\NVIDIA App\Plugins\oc"
set "TARGET_DIR=%PF%\NVIDIA Corporation\NVIDIA App\Plugins\localuser\oc"
set "NVAPP_DIR=%PF%\NVIDIA Corporation\NVIDIA App\Plugins\localuser\NvApp"

if not exist "%OC_DIR%" (
    echo [ERROR] Directory "%OC_DIR%" not found.
    echo Please make sure NVIDIA App is installed.
    echo.
    pause
    exit /b 1
)

echo [1/3] Connecting overclocking plugin to NVIDIA Container...
if not exist "%TARGET_DIR%" (
    mklink /J "%TARGET_DIR%" "%OC_DIR%"
    if %errorlevel% equ 0 (
        echo [OK] Junction link successfully created.
    ) else (
        echo [!] Junction failed, copying plugin files directly...
        copy /Y "%OC_DIR%\_OverClockingNvc.*" "%NVAPP_DIR%\"
    )
) else (
    echo [OK] Overclocking plugin is already linked.
)

echo.
echo [2/3] Restarting NVIDIA services...
net stop NvContainerLocalSystem >nul 2>&1
net start NvContainerLocalSystem >nul 2>&1

taskkill /f /im nvcontainer.exe /fi "SESSION ne 0" >nul 2>&1
taskkill /f /im "NVIDIA App.exe" >nul 2>&1

echo.
echo [3/3] Fix applied successfully!
echo.
echo =========================================================
echo NEXT STEPS:
echo 1. Close background apps using GPU (browsers, Discord, Steam).
echo 2. Open NVIDIA App.
echo 3. Go to System -^> Performance.
echo 4. Toggle 'Automatic Tuning' ON.
echo =========================================================
echo.
pause
