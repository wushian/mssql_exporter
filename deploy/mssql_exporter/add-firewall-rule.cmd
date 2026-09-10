@echo off
setlocal

:: ============================================================
:: mssql_exporter - Add inbound firewall rule for TCP 9399
:: Must be run as Administrator
::
:: Usage: add-firewall-rule.cmd [port]
::   port defaults to 9399 - keep it in sync with LISTEN_PORT in
::   service-config.cmd (or PROMETHEUS_MSSQL_ServerPort when you
::   run the exporter some other way).
::
:: install-service.cmd already does this when OPEN_FIREWALL=1; this
:: script is for deployments that start the exporter without NSSM
:: (run-mssql_exporter.cmd, sc create, a scheduler). The rule name is
:: the same one install/uninstall-service.cmd use, so running both
:: never leaves two rules behind. For the companion sql_exporter run
:: it once more with 9237.
::
:: Port-based on purpose (no exe path): the folder can move between
:: machines, the port is the stable contract. profile=any because an
:: intranet server's network profile is often unknown at deploy time.
:: ============================================================

set "PORT=%~1"
if "%PORT%"=="" set "PORT=9399"

:: ---- Validate port is numeric -------------------------------
:: Deliberately BEFORE the admin check: the validation branch can
:: then be tested safely even in an elevated shell (never reaches
:: netsh).
echo %PORT%| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 (
    echo [ERROR] Invalid port: "%PORT%". Usage: add-firewall-rule.cmd [port]
    pause
    exit /b 1
)

set "RULE_NAME=MSSQL Exporter for Prometheus - TCP %PORT%"

:: ---- Check Administrator privileges ------------------------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Please re-run this script as Administrator.
    pause
    exit /b 1
)

echo.
echo Rule name : %RULE_NAME%
echo Port      : TCP %PORT% (inbound)
echo.

:: ---- Remove existing rule if present (idempotent re-run) ---
netsh advfirewall firewall show rule name="%RULE_NAME%" >nul 2>&1
if %errorlevel% equ 0 (
    echo [INFO] Existing rule found. Removing...
    netsh advfirewall firewall delete rule name="%RULE_NAME%" >nul
)

:: ---- Add rule ----------------------------------------------
echo [1/1] Adding inbound firewall rule...
netsh advfirewall firewall add rule name="%RULE_NAME%" dir=in action=allow protocol=TCP localport=%PORT% profile=any

if %errorlevel% neq 0 (
    echo [ERROR] netsh failed to add the firewall rule (errorlevel=%errorlevel%).
    pause
    exit /b 1
)

echo.
echo [DONE] Inbound TCP %PORT% allowed.
echo        Prometheus can now scrape http://^<this-host^>:%PORT%/metrics
echo.
pause
endlocal
