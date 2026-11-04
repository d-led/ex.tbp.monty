@echo off
rem
rem The release as a web server, in the form Windows runs: the same overlay as
rem `bin/server`, which is a shell script and cannot be executed here. PHX_SERVER
rem is what config/runtime.exs waits for before it starts the endpoint, so the
rem same release can also be used as a one-off CLI.
rem
rem `ex_tbp_monty.bat` is the launcher `mix release` writes; this file adds the
rem three things the server does before it starts — create WANDB_DIR, migrate,
rem then hand over.
setlocal
cd /d "%~dp0"

rem wandb only uses WANDB_DIR if the directory is already there: given one that
rem is not, it warns once and writes to the system temp directory instead, which
rem is not on the volume, and a volume is empty on its first boot.
rem
rem Not fatal, and not silent: a directory this account cannot write cannot be
rem fixed from here, and the run should still start.
if defined WANDB_DIR if not exist "%WANDB_DIR%\" (
  mkdir "%WANDB_DIR%" 2>nul
  if errorlevel 1 echo the release cannot write %WANDB_DIR%; wandb will use the system temp directory 1>&2
)

rem The schema comes up with the release, before anything else starts: starting
rem the application is then the whole of a deploy, with no migration step to
rem forget and nothing serving against tables that are not there yet. Ecto takes
rem the migration lock, so several instances booting at once migrate once.
rem
rem `bin\migrate.bat` is the same call for an operator who wants to migrate
rem without starting a server.
if not "%MIGRATE_ON_BOOT%"=="false" (
  call "%~dp0ex_tbp_monty.bat" eval "ExTbpMonty.Release.migrate"
  if errorlevel 1 exit /b 1
)

set PHX_SERVER=true
call "%~dp0ex_tbp_monty.bat" start
exit /b %errorlevel%
