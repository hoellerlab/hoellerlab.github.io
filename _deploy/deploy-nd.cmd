@echo off
rem Runs deploy-nd.ps1 even though PowerShell script execution is disabled on this machine.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy-nd.ps1" %*
