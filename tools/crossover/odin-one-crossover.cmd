@echo off
setlocal enabledelayedexpansion

set "ROOT=%~dp0..\.."
pushd "%ROOT%"

echo.
echo Odin's Cat HALO for Windows / CrossOver
echo ======================================
echo.
echo This runner builds the Windows Tauri app inside the current CrossOver bottle.
echo The app keeps using the same .odinone-access.json profile file as Android.
echo.

where node >nul 2>nul
if errorlevel 1 (
  echo Node.js was not found in this CrossOver bottle.
  echo Install Node.js LTS for Windows inside the bottle, then run this file again.
  goto :fail
)

where npm >nul 2>nul
if errorlevel 1 (
  echo npm was not found in this CrossOver bottle.
  echo Reinstall Node.js LTS for Windows inside the bottle, then run this file again.
  goto :fail
)

where cargo >nul 2>nul
if errorlevel 1 (
  echo Rust/Cargo was not found in this CrossOver bottle.
  echo Install Rust for Windows from https://rustup.rs, then run this file again.
  goto :fail
)

echo Installing JavaScript dependencies...
call npm install
if errorlevel 1 goto :fail

echo.
echo Building Windows installer...
call npm run windows:tauri:build
if errorlevel 1 goto :fail

echo.
echo Looking for generated installer...
set "FOUND="
for %%F in ("apps\desktop\src-tauri\target\release\bundle\nsis\*.exe") do (
  set "FOUND=%%~fF"
)

if not defined FOUND (
  for %%F in ("apps\desktop\src-tauri\target\release\bundle\msi\*.msi") do (
    set "FOUND=%%~fF"
  )
)

if not defined FOUND (
  echo Build finished, but no NSIS EXE or MSI installer was found.
  echo Check apps\desktop\src-tauri\target\release\bundle
  goto :fail
)

echo.
echo Starting installer:
echo !FOUND!
start "" "!FOUND!"
goto :done

:fail
echo.
echo CrossOver setup is not complete yet.
echo Required inside the bottle: Node.js LTS, Rust stable, Visual Studio C++ Build Tools, Microsoft WebView2 Runtime.
echo.
pause
popd
exit /b 1

:done
echo.
echo Done.
popd
pause
