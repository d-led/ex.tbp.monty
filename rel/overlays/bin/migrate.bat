@echo off
rem
rem Migrations as a deploy step, not as part of the boot: the Windows form of
rem `bin/migrate`. Two instances migrating at boot is the race this avoids.
setlocal
cd /d "%~dp0"

rem `%CD%`, not `%~dp0`: the note in `server.bat` says why.

call "%CD%\ex_tbp_monty.bat" eval "ExTbpMonty.Release.migrate"
exit /b %errorlevel%
