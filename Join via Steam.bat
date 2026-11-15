@echo off
title Vagabond VTT - Join via Steam
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vtt-server.ps1" -Join %*
echo.
pause
