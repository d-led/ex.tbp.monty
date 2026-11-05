@echo off
rem
rem Migrations as a deploy step, not as part of the boot: the Windows form of
rem `bin/migrate`. Two instances migrating at boot is the race this avoids.
setlocal
set "HERE=%~dp0"
set "HERE=%HERE:/=\%"
cd /d "%HERE%"

rem `%HERE%`, the folder this file is in: `%CD%` would be wherever the caller
rem happened to be, and `cd /d` cannot reach a UNC path. `server.bat` says more.
call "%HERE%ex_tbp_monty.bat" eval "ExTbpMonty.Release.migrate"
exit /b %errorlevel%
