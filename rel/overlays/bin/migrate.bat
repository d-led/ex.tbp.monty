@echo off
rem
rem Migrations as a deploy step, not as part of the boot: the Windows form of
rem `bin/migrate`. Two instances migrating at boot is the race this avoids.
setlocal
cd /d "%~dp0"

call "%~dp0ex_tbp_monty.bat" eval "ExTbpMonty.Release.migrate"
exit /b %errorlevel%
