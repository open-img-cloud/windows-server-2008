@echo off
rem First logon of the build VM (run by autounattend.xml, as Administrator).
rem Copies oic\ from the OIC_SETUP CD (%1, for example E:) to C:\oic and
rem registers C:\oic\setup.cmd as a startup task running as SYSTEM, so that
rem the build goes on across the reboots without any logon.
setlocal
set SRC=%~1
if not exist C:\oic mkdir C:\oic
xcopy /e /i /y /q "%SRC%\oic" C:\oic >nul
(echo 1)> C:\oic\stage.txt
echo [%date% %time%] oic-setup: first logon, setup task registered> COM1
schtasks /create /tn oic-setup /tr "C:\oic\setup.cmd" /sc onstart /ru SYSTEM /rl HIGHEST /f >nul
schtasks /run /tn oic-setup >nul
