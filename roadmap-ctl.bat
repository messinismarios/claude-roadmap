@echo off
rem part of ftero-scripts (github.com/messinismarios/ftero-scripts)
rem Sends a stop/retry/pivot/status command to a running run-roadmap.sh, via
rem Git Bash's real bash.exe directly -- see run-roadmap.bat for why plain
rem `bash` on PATH can't be trusted on Windows (it often resolves to the WSL
rem launcher shim, not Git Bash).
rem
rem Run this from the same target repo directory run-roadmap.bat was run
rem from -- see the note in that file about why.
rem
rem Usage:
rem   path\to\ftero-scripts\roadmap-ctl.bat stop
rem   path\to\ftero-scripts\roadmap-ctl.bat retry
rem   path\to\ftero-scripts\roadmap-ctl.bat pivot "text to send into the running turn"
rem   path\to\ftero-scripts\roadmap-ctl.bat status
setlocal

set "GITBASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%GITBASH%" set "GITBASH=%ProgramFiles(x86)%\Git\bin\bash.exe"

if not exist "%GITBASH%" (
    echo Could not find Git Bash at "%ProgramFiles%\Git\bin\bash.exe".
    echo Install Git for Windows, or edit GITBASH in this file to match your install.
    exit /b 1
)

"%GITBASH%" "%~dp0roadmap-ctl.sh" %*
exit /b %errorlevel%
