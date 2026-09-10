@echo off
rem ============================================================================
rem  service-control.cmd - day-to-day control of the installed service.
rem
rem    service-control.cmd start
rem    service-control.cmd stop
rem    service-control.cmd restart     (use after unzipping a new version)
rem    service-control.cmd status
rem    service-control.cmd logs        (tail the NSSM stdout/stderr logs)
rem    service-control.cmd edit        (open the NSSM settings GUI)
rem
rem  start/stop/restart/edit need Administrator; status/logs do not.
rem ============================================================================
setlocal EnableExtensions

if not exist "%~dp0service-config.cmd" (
    echo [ERROR] service-config.cmd not found - run install-service.cmd first.
    exit /b 1
)
call "%~dp0service-config.cmd"
if errorlevel 1 (
    echo [ERROR] service-config.cmd failed to load.
    exit /b 1
)

if not exist "%NSSM_EXE%" (
    echo [ERROR] nssm.exe not found: %NSSM_EXE%
    exit /b 1
)

set "ACTION=%~1"
if "%ACTION%"=="" set "ACTION=status"

if /i "%ACTION%"=="start"   goto :start
if /i "%ACTION%"=="stop"    goto :stop
if /i "%ACTION%"=="restart" goto :restart
if /i "%ACTION%"=="status"  goto :status
if /i "%ACTION%"=="logs"    goto :logs
if /i "%ACTION%"=="edit"    goto :edit

echo Usage: %~nx0 [start^|stop^|restart^|status^|logs^|edit]
exit /b 1

:start
call :need_admin || exit /b 1
call :check_port || exit /b 1
"%NSSM_EXE%" start "%SERVICE_NAME%"
goto :status

:stop
call :need_admin || exit /b 1
"%NSSM_EXE%" stop "%SERVICE_NAME%"
goto :status

:restart
call :need_admin || exit /b 1
"%NSSM_EXE%" restart "%SERVICE_NAME%"
goto :status

:edit
call :need_admin || exit /b 1
"%NSSM_EXE%" edit "%SERVICE_NAME%"
exit /b 0

:status
echo.
sc query "%SERVICE_NAME%"
echo.
echo   URL  : %DISPLAY_URL%
echo   Logs : %LOG_DIR%
exit /b 0

:logs
echo === service-stderr.log (last 40 lines) ===
powershell -NoProfile -Command "if (Test-Path '%LOG_DIR%\service-stderr.log') { Get-Content '%LOG_DIR%\service-stderr.log' -Tail 40 } else { 'no stderr log yet' }"
echo.
echo === service-stdout.log (last 60 lines) ===
powershell -NoProfile -Command "if (Test-Path '%LOG_DIR%\service-stdout.log') { Get-Content '%LOG_DIR%\service-stdout.log' -Tail 60 } else { 'no stdout log yet' }"
exit /b 0

:need_admin
net session >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Administrator rights required for "%ACTION%".
    exit /b 1
)
exit /b 0

rem Guards "start" only. NOT used for "restart": there the port is legitimately
rem held by the very instance being restarted. An already-RUNNING service owns
rem the port too, so that case is let through and "start" stays a harmless no-op.
:check_port
if "%LISTEN_PORT%"=="" exit /b 0
sc query "%SERVICE_NAME%" | findstr /i "RUNNING" >nul
if not errorlevel 1 exit /b 0
netstat -ano | findstr /r /c:":%LISTEN_PORT% " | findstr /i /c:"LISTENING" >nul
if errorlevel 1 exit /b 0
echo.
echo [ERROR] TCP port %LISTEN_PORT% is already in use - not starting the service.
echo         It would fail to bind, and NSSM would keep restarting it while
echo         reporting a successful start. Currently listening:
echo.
netstat -ano | findstr /r /c:":%LISTEN_PORT% " | findstr /i /c:"LISTENING"
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /r /c:":%LISTEN_PORT% " ^| findstr /i /c:"LISTENING"') do @call :show_pid %%P
echo.
echo         Free the port, or change LISTEN_PORT in service-config.cmd and
echo         re-run install-service.cmd.
exit /b 1

rem IPv4 and IPv6 produce one netstat line each for the same listener; skip the
rem repeat. A called label is re-parsed on every call, so a plain %VAR% works
rem here where an inline for-loop body would need delayed expansion.
:show_pid
if "%PID_SHOWN%"=="%1" exit /b 0
set "PID_SHOWN=%1"
echo.
echo         Held by PID %1:
tasklist /fi "PID eq %1" /nh 2>nul
exit /b 0
