@echo off
rem
rem The data a run reads, as a step before the server: the Windows form of
rem `bin/prerequisites`. Every start after the first finds the bundles on disk
rem and does nothing.
rem
rem It exits non-zero when a download does not arrive, which is deliberate: a
rem server that started anyway would offer runs whose model is missing.
setlocal
cd /d "%~dp0"

call "%~dp0ex_tbp_monty.bat" eval "ExTbpMonty.Release.fetch_prerequisites"
exit /b %errorlevel%
