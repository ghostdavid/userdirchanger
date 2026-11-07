@echo off
setlocal
chcp 65001 >nul
title Windows User Folder Migration

set "SCRIPT=%~dp0Start-UserFolderMigration.ps1"
set "PREVIEW="
if /i "%~1"=="--preview" set "PREVIEW=-Preview"

if not exist "%SCRIPT%" (
    echo [ERROR] Start-UserFolderMigration.ps1 was not found.
    echo Keep the CMD file and both PS1 files in the same folder.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %PREVIEW%
exit /b %ERRORLEVEL%
