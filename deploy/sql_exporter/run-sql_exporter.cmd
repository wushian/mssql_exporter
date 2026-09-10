@echo off
REM Start sql_exporter with config.yml from this folder. Keep this file ASCII-only:
REM cmd.exe reads batch files in the OEM code page and breaks on UTF-8 comments.
REM Default listen address is 0.0.0.0:9237. For a Windows service, point nssm at this .cmd.
setlocal
cd /d "%~dp0"
set LISTEN=0.0.0.0:9237
if not exist "%~dp0sql_exporter.exe" (
  echo sql_exporter.exe not found. Run build-sql_exporter.ps1 first.
  exit /b 1
)
REM Full path on purpose: with NoDefaultCurrentDirectoryInExePath set, cmd does not search the current folder.
"%~dp0sql_exporter.exe" -config.file "%~dp0config.yml" -web.listen-address %LISTEN%
