@echo off
rem part of ftero-scripts (github.com/messinismarios/ftero-scripts)
rem Launches run-roadmap.sh with Git Bash directly, bypassing the WSL "bash"
rem shim at C:\Windows\System32\bash.exe that plain `bash script.sh` resolves
rem to on most Windows PATHs (and which fails if the default WSL distro has
rem no usable /bin/bash, e.g. the docker-desktop distro).
rem
rem IMPORTANT: run this from a shell whose current directory is the TARGET
rem repo (the one with specs/roadmap.md and scripts/roadmap.config.sh) --
rem this script is repo-agnostic and reads the current directory, not its
rem own location, as the workspace. Double-clicking this file directly
rem targets whatever folder it's sitting in, which is usually wrong -- open
rem a shell in the target repo first, e.g.:
rem   cd C:\code\some-product && C:\code\ftero-scripts\run-roadmap.bat
setlocal

set "GITBASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%GITBASH%" set "GITBASH=%ProgramFiles(x86)%\Git\bin\bash.exe"

if not exist "%GITBASH%" (
    echo Could not find Git Bash at "%ProgramFiles%\Git\bin\bash.exe".
    echo Install Git for Windows, or edit GITBASH in this file to match your install.
    pause
    exit /b 1
)

"%GITBASH%" "%~dp0run-roadmap.sh" %*

echo.
echo ==== run-roadmap.sh exited with code %errorlevel% ====
pause