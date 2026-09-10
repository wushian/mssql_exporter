@echo off
rem ============================================================================
rem  uninstall-service.cmd - stop and remove the NSSM service.
rem
rem  Removes only the service and the firewall rule. The application folder is
rem  left untouched: service-config.cmd, metrics.json and logs stay where they
rem  are, so re-installing later picks up the same state.
rem
rem  Run as Administrator.
rem ============================================================================
setlocal EnableExtensions

if not exist "%~dp0service-config.cmd" (
    echo [..] service-config.cmd not found - the service was never installed here.
    exit /b 0
)
call "%~dp0service-config.cmd"
if errorlevel 1 (
    echo [ERROR] service-config.cmd failed to load.
    exit /b 1
)

net session >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Administrator rights required.
    exit /b 1
)

if not exist "%NSSM_EXE%" (
    echo [ERROR] nssm.exe not found: %NSSM_EXE%
    exit /b 1
)

sc query "%SERVICE_NAME%" >nul 2>&1
if errorlevel 1 (
    echo [..] Service "%SERVICE_NAME%" is not installed - nothing to remove.
    goto :cleanup
)

echo [..] Stopping "%SERVICE_NAME%".
"%NSSM_EXE%" stop "%SERVICE_NAME%" >nul 2>&1

rem The SCM keeps the service "marked for deletion" until every handle is
rem closed; give the process time to actually exit first.
timeout /t 3 /nobreak >nul 2>&1 || ping -n 4 127.0.0.1 >nul

echo [..] Removing service.
"%NSSM_EXE%" remove "%SERVICE_NAME%" confirm
if errorlevel 1 (
    echo [ERROR] nssm remove failed. Close services.msc if it is open and retry -
    echo         an open handle keeps the service in "marked for deletion".
    exit /b 1
)

:cleanup
netsh advfirewall firewall show rule name="%FW_RULE_NAME%" >nul 2>&1
if not errorlevel 1 (
    echo [..] Removing firewall rule.
    netsh advfirewall firewall delete rule name="%FW_RULE_NAME%" >nul
)

echo.
echo === Removed. The application folder was left as-is: %APP_DIR%
echo.
exit /b 0
