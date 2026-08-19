@echo off
setlocal EnableExtensions DisableDelayedExpansion

chcp 65001 >nul 2>&1
cd /d "%~dp0" || exit /b 2

title Endpoint Provisioning Kit

set "ROOT=%CD%"
set "SCRIPT=%ROOT%\EndpointProvisioning.ps1"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" (
    set "PS_EXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
)

if not exist "%SCRIPT%" (
    echo [ERROR] EndpointProvisioning.ps1 was not found next to this launcher.
    pause
    exit /b 2
)

if not exist "%PS_EXE%" (
    echo [ERROR] Windows PowerShell 5.1 was not found.
    pause
    exit /b 3
)

net session >nul 2>&1
if errorlevel 1 (
    set "EPK_BAT=%~f0"
    set "EPK_ROOT=%ROOT%"
    set "EPK_ARGS=%*"

    "%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
        "$cmd = '"' + $env:EPK_BAT + '"'; if ($env:EPK_ARGS) { $cmd += ' ' + $env:EPK_ARGS }; Start-Process -FilePath $env:ComSpec -ArgumentList '/d','/c',$cmd -WorkingDirectory $env:EPK_ROOT -Verb RunAs"

    exit /b %ERRORLEVEL%
)

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo [EPK] Execution finished with code %RC%.
    echo [EPK] Review Runtime\Logs and Runtime\Reports for details.
    pause
)

exit /b %RC%
