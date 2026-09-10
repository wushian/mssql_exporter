@echo off
REM Start mssql_exporter from this folder. Keep this file ASCII-only and use full paths:
REM cmd.exe reads batch files in the OEM code page, and with NoDefaultCurrentDirectoryInExePath
REM set it does not search the current folder for executables.
REM
REM First start: copies config.json.example / metrics.json.example into place.
REM Upgrades: unzip over this folder; the real files are never in the zip, so they survive.
REM
REM Connection string: set PROMETHEUS_MSSQL_DataSource as a system environment variable
REM (required for services), or put {"DataSource": "..."} in an appsettings.json next to the exe.
setlocal
cd /d "%~dp0"
if not exist "%~dp0config.json"  copy /y "%~dp0config.json.example"  "%~dp0config.json"  >nul
if not exist "%~dp0metrics.json" copy /y "%~dp0metrics.json.example" "%~dp0metrics.json" >nul
if not exist "%~dp0mssql_exporter.exe" (
  echo mssql_exporter.exe not found next to this script.
  exit /b 1
)
"%~dp0mssql_exporter.exe" serve %*
