@echo off
rem ============================================================================
rem  install-service.cmd - install (or re-install) mssql_exporter as a Windows
rem  service via NSSM.
rem
rem  Run as Administrator, from the folder that holds nssm.exe + the exe.
rem  Safe to re-run: an existing service is stopped, REMOVED, and re-created
rem  from scratch with the current settings, then started - unless LISTEN_PORT
rem  turns out to be held by another process, in which case the service is left
rem  installed but not started.
rem
rem  Settings live in service-config.cmd (created from the .example on first run).
rem ============================================================================
setlocal EnableExtensions

rem --- first run: create the editable config from the shipped example ---------
if exist "%~dp0service-config.cmd" goto :have_config
if not exist "%~dp0service-config.cmd.example" (
    echo [ERROR] Neither service-config.cmd nor service-config.cmd.example found
    echo         next to this script.
    exit /b 1
)
copy /y "%~dp0service-config.cmd.example" "%~dp0service-config.cmd" >nul
echo.
echo [..] Created service-config.cmd from the shipped example.
echo      Edit DATASOURCE and LISTEN_PORT in it, then run this script again.
echo.
exit /b 1
:have_config

call "%~dp0service-config.cmd"
if errorlevel 1 (
    echo [ERROR] service-config.cmd failed to load.
    exit /b 1
)

echo.
echo === Installing service "%SERVICE_NAME%" ===
echo   folder : %APP_DIR%
echo   exe    : %APP_EXE% serve
echo   port   : %LISTEN_PORT%  ^(all interfaces^)
echo   log    : %LOG_LEVEL%
echo.

rem --- preflight ---------------------------------------------------------------

net session >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Administrator rights required.
    echo         Right-click this file and choose "Run as administrator".
    exit /b 1
)

if not exist "%NSSM_EXE%" (
    echo [ERROR] nssm.exe not found: %NSSM_EXE%
    echo         nssm.exe must sit in the SAME folder as %APP_EXE_NAME%.
    echo         Run get-nssm.cmd, or download https://nssm.cc/download and
    echo         copy win64\nssm.exe here.
    exit /b 1
)

if not exist "%APP_EXE%" (
    echo [ERROR] %APP_EXE_NAME% not found: %APP_EXE%
    exit /b 1
)

rem The exporter needs a connection string from somewhere, or it exits at once
rem with "Expected DataSource" and NSSM would restart it forever.
if not "%DATASOURCE%"=="" goto :datasource_ok
if exist "%APP_DIR%\appsettings.json" goto :datasource_ok
echo [ERROR] DATASOURCE is empty in service-config.cmd and there is no
echo         appsettings.json next to the exe. Set one of them first.
exit /b 1
:datasource_ok

rem The zip ships config.json / metrics.json as examples only so an upgrade
rem never overwrites the site's query file. Create the real ones on first install.
if not exist "%APP_DIR%\config.json"  if exist "%APP_DIR%\config.json.example"  copy /y "%APP_DIR%\config.json.example"  "%APP_DIR%\config.json"  >nul
if not exist "%APP_DIR%\metrics.json" if exist "%APP_DIR%\metrics.json.example" copy /y "%APP_DIR%\metrics.json.example" "%APP_DIR%\metrics.json" >nul
if not exist "%APP_DIR%\metrics.json" (
    echo [ERROR] metrics.json not found and no metrics.json.example to copy from.
    exit /b 1
)

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

rem --- remove any existing service, then create fresh --------------------------
rem  Re-configuring in place would only overwrite the keys this script sets;
rem  anything removed from service-config.cmd since the last install would
rem  silently survive. Stop + remove + fresh install makes the installed service
rem  match service-config.cmd exactly.

sc query "%SERVICE_NAME%" >nul 2>&1
if errorlevel 1 goto :create

echo [..] Service already exists - stopping and removing it first.
"%NSSM_EXE%" stop "%SERVICE_NAME%" >nul 2>&1

rem The SCM keeps a service "marked for deletion" until every handle is closed;
rem give the process time to actually exit before removing.
timeout /t 3 /nobreak >nul 2>&1 || ping -n 4 127.0.0.1 >nul

"%NSSM_EXE%" remove "%SERVICE_NAME%" confirm >nul 2>&1
if errorlevel 1 goto :remove_failed

rem Give the SCM a moment to finish the deletion before re-creating the name.
timeout /t 2 /nobreak >nul 2>&1 || ping -n 3 127.0.0.1 >nul

:create
echo [..] Creating service.
"%NSSM_EXE%" install "%SERVICE_NAME%" "%APP_EXE%"
if errorlevel 1 (
    echo [ERROR] nssm install failed.
    exit /b 1
)

:configure
echo [..] Applying configuration.

rem AppParameters MUST be "serve": under NSSM the parent process is nssm.exe,
rem not services.exe, so IsWindowsService() is false and without the argument
rem the exporter just prints its help and exits - a restart loop.
call :nset Application "%APP_EXE%"                           || exit /b 1
call :nset AppDirectory "%APP_DIR%"                          || exit /b 1
call :nset AppParameters "serve"                             || exit /b 1
call :nset DisplayName "%SERVICE_DISPLAY%"                   || exit /b 1
call :nset Description "%SERVICE_DESC%"                      || exit /b 1

rem Delayed start: the network (and a local SQL Server) come up first.
call :nset Start SERVICE_DELAYED_AUTO_START                  || exit /b 1

rem Console stdout/stderr -> rotating files. Startup exceptions and the
rem "Expected DataSource" exit only show up here.
call :nset AppStdout "%LOG_DIR%\service-stdout.log"          || exit /b 1
call :nset AppStderr "%LOG_DIR%\service-stderr.log"          || exit /b 1
call :nset AppRotateFiles 1                                  || exit /b 1
call :nset AppRotateOnline 1                                 || exit /b 1
call :nset AppRotateSeconds 86400                            || exit /b 1
call :nset AppRotateBytes 10485760                           || exit /b 1

rem Stop: send Ctrl+C first so in-flight SQL queries are cancelled cleanly,
rem then escalate. Do NOT set AppNoConsole 1 - without a console there is no
rem Ctrl+C and graceful shutdown never runs.
call :nset AppStopMethodConsole 15000                        || exit /b 1
call :nset AppStopMethodWindow 5000                          || exit /b 1
call :nset AppStopMethodThreads 5000                         || exit /b 1

rem Crash -> restart after 5s; a process that dies within 10s counts as
rem "failed to start" so NSSM backs off instead of spinning.
call :nset AppExit Default Restart                           || exit /b 1
call :nset AppRestartDelay 5000                              || exit /b 1
call :nset AppThrottle 10000                                 || exit /b 1

rem Environment. The exporter reads PROMETHEUS_MSSQL_* (it ignores
rem ASPNETCORE_URLS because it calls UseUrls itself). Kept OUT of any if(...)
rem block on purpose: a ")" inside the connection string would break cmd there.
if "%DATASOURCE%"=="" goto :env_without_datasource
call :nset AppEnvironmentExtra "PROMETHEUS_MSSQL_ServerPort=%LISTEN_PORT%" "PROMETHEUS_MSSQL_Serilog__MinimumLevel=%LOG_LEVEL%" "DOTNET_ENVIRONMENT=Production" "PROMETHEUS_MSSQL_DataSource=%DATASOURCE%" || exit /b 1
goto :env_done
:env_without_datasource
call :nset AppEnvironmentExtra "PROMETHEUS_MSSQL_ServerPort=%LISTEN_PORT%" "PROMETHEUS_MSSQL_Serilog__MinimumLevel=%LOG_LEVEL%" "DOTNET_ENVIRONMENT=Production" || exit /b 1
:env_done

if "%DEPENDS_ON%"=="" goto :deps_done
call :nset DependOnService "%DEPENDS_ON%"                    || exit /b 1
:deps_done

rem --- service account ---------------------------------------------------------

if "%SERVICE_ACCOUNT%"=="" goto :account_done

echo [..] Setting service account: %SERVICE_ACCOUNT%
if "%SERVICE_PASSWORD%"=="" goto :account_nopass
"%NSSM_EXE%" set "%SERVICE_NAME%" ObjectName "%SERVICE_ACCOUNT%" "%SERVICE_PASSWORD%" >nul
goto :account_set
:account_nopass
"%NSSM_EXE%" set "%SERVICE_NAME%" ObjectName "%SERVICE_ACCOUNT%" >nul
:account_set
if errorlevel 1 (
    echo [ERROR] Could not set the service account.
    exit /b 1
)

rem No urlacl step here: Kestrel is a socket server and does not go through
rem http.sys, so a non-elevated account needs no URL reservation.

rem The service writes logs into its own folder; grant Modify. The (OI)(CI)
rem parentheses are why this line must NOT sit inside an if(...) block.
echo [..] Granting Modify on %APP_DIR% to %SERVICE_ACCOUNT%
icacls "%APP_DIR%" /grant "%SERVICE_ACCOUNT%":(OI)(CI)M /T >nul 2>&1

echo [!!] Still manual: grant "Log on as a service" to %SERVICE_ACCOUNT%
echo      (secpol.msc - Local Policies - User Rights Assignment).

:account_done

rem --- firewall ----------------------------------------------------------------

if not "%OPEN_FIREWALL%"=="1" goto :fw_done
netsh advfirewall firewall show rule name="%FW_RULE_NAME%" >nul 2>&1
if not errorlevel 1 goto :fw_done
echo [..] Opening inbound TCP %LISTEN_PORT%
netsh advfirewall firewall add rule name="%FW_RULE_NAME%" dir=in action=allow protocol=TCP localport=%LISTEN_PORT% >nul
:fw_done

rem --- port conflict check -----------------------------------------------------
rem  Sits HERE, after the old service was stopped and removed: a preflight check
rem  would see the port held by the very instance being replaced.
rem   - plain "netstat -ano": "-p tcp" would silently limit it to IPv4.
rem   - ":%LISTEN_PORT% " keeps the trailing space so :9399 does not match :93990.
rem   - the LISTENING filter drops TIME_WAIT rows, which are not conflicts.
rem   - /c: keeps a pattern with a space as ONE pattern.

if "%LISTEN_PORT%"=="" goto :port_ok
netstat -ano | findstr /r /c:":%LISTEN_PORT% " | findstr /i /c:"LISTENING" >nul
if not errorlevel 1 goto :port_busy
:port_ok

rem --- start -------------------------------------------------------------------

echo [..] Starting service.
"%NSSM_EXE%" start "%SERVICE_NAME%"
if errorlevel 1 (
    echo [ERROR] Service did not start. See %LOG_DIR%\service-stderr.log
    exit /b 1
)

rem NSSM reports success as soon as the process is spawned. Wait, then re-check:
rem a crash-on-startup shows up only here, as a restart loop behind a green
rem "started" result.
timeout /t 6 /nobreak >nul 2>&1 || ping -n 7 127.0.0.1 >nul

sc query "%SERVICE_NAME%" | findstr /i "RUNNING" >nul
if errorlevel 1 (
    echo.
    echo [ERROR] Service is not RUNNING after startup - it most likely crashed
    echo         and is being restarted in a loop. Check, in this order:
    echo           %LOG_DIR%\service-stderr.log   ^(e.g. "Expected DataSource"^)
    echo           %LOG_DIR%\service-stdout.log
    sc query "%SERVICE_NAME%"
    exit /b 1
)

echo.
echo === Done ===
echo   Service : %SERVICE_NAME% (RUNNING, delayed auto-start)
echo   URL     : %DISPLAY_URL%
echo   Logs    : %LOG_DIR%\service-stdout.log
echo.
echo   Control it with:  service-control.cmd status ^| restart ^| stop ^| logs
echo.
exit /b 0

:remove_failed
echo [ERROR] Could not remove the existing service. Close services.msc if it is
echo         open and retry - an open handle keeps it "marked for deletion".
exit /b 1

:port_busy
echo.
echo [ERROR] TCP port %LISTEN_PORT% is already in use - not starting the service.
echo         It would fail to bind, and NSSM would keep restarting it while
echo         reporting a successful start. Currently listening:
echo.
netstat -ano | findstr /r /c:":%LISTEN_PORT% " | findstr /i /c:"LISTENING"
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /r /c:":%LISTEN_PORT% " ^| findstr /i /c:"LISTENING"') do @call :show_pid %%P
echo.
echo         The service IS installed and configured - only the start was
echo         skipped. Free the port, or change LISTEN_PORT in
echo         service-config.cmd and re-run this script, then start it with:
echo             service-control.cmd start
exit /b 1

rem --- helpers -----------------------------------------------------------------

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

:nset
"%NSSM_EXE%" set "%SERVICE_NAME%" %* >nul
if errorlevel 1 (
    echo [ERROR] nssm set %1 failed.
    exit /b 1
)
exit /b 0
