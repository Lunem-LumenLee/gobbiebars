@echo off
setlocal enableextensions

REM Go to the folder where this .bat lives (handles "Run as administrator" too)
pushd "%~dp0"

REM --- OPTION A: include files (default) ---
tree /f /a . > "folder-structure.txt"

REM --- OPTION B: folders only ---
REM tree /a . > "folder-structure.txt"

echo Created "%CD%\folder-structure.txt"
popd
endlocal
