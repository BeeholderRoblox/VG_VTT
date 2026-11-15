@echo off
title Vagabond VTT - Game Server
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vtt-server.ps1" %*
echo.
pause
