@echo off
setlocal
chcp 65001 >nul

:: Self-elevation to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [i] Requesting Administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

title NVIDIA App Automatic Tuning Fix

:: If Fix_NVIDIA_App.ps1 or fix_nvidia.ps1 exists next to this bat, run it
if exist "%~dp0Fix_NVIDIA_App.ps1" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fix_NVIDIA_App.ps1"
    exit /b %errorlevel%
)
if exist "%~dp0fix_nvidia.ps1" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix_nvidia.ps1"
    exit /b %errorlevel%
)

echo [ERROR] Fix script (.ps1) not found next to this batch file.
pause
