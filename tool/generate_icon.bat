@echo off
REM Converts the SVG icon to PNG and generates all platform launcher icons.
REM Requires: npx (Node.js), flutter_launcher_icons (dev dependency)

cd /d "%~dp0.."

echo Converting SVG to PNG...
call npx --yes sharp-cli -i assets/app_icon.svg -o assets/app_icon.png resize 1024 1024
if errorlevel 1 exit /b 1

echo Generating launcher icons...
call dart run flutter_launcher_icons
if errorlevel 1 exit /b 1

echo Done!
