@echo off
rem Syntax check, then the full test run. Exit code 0 only if both pass. Run from anywhere.
set "ROOT=%~dp0.."
luajit "%ROOT%\test\harness\syntax_check.lua"
if errorlevel 1 exit /b %errorlevel%
luajit "%ROOT%\test\harness\run.lua"
exit /b %errorlevel%
