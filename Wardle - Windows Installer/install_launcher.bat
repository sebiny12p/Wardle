@echo off
:: Force the script to run from the current folder
cd /d "%~dp0"

:: Run the PowerShell script located in this specific folder
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wardle_setup.ps1"

PAUSE