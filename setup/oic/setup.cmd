@echo off
rem In-guest build of the Windows Server 2008 image, one stage per boot.
rem Runs as SYSTEM from the startup task registered by start.cmd. The stage
rem number is kept in C:\oic\stage.txt; each stage installs one package
rem from the OIC_SETUP CD and reboots. Progress goes to C:\oic\setup.log and
rem to COM1 (the build log). The last line is OIC-SETUP-DONE, or
rem OIC-SETUP-FAILED followed by a power off.
setlocal enableextensions
cd /d C:\oic
set SRC=
for %%d in (D E F G H) do if exist %%d:\oic\setup.cmd set SRC=%%d:
set /p STAGE=<C:\oic\stage.txt
call :log "boot, stage %STAGE%, setup CD %SRC%"
if "%SRC%"=="" call :fail "OIC_SETUP CD not found" & goto :eof
rem Let the services (Windows Modules Installer, ...) settle after boot.
ping -n 31 127.0.0.1 >nul
goto stage%STAGE%

:stage1
call :log "Windows Server 2008 SP2 (KB948465), the longest step"
"%SRC%\updates\sp2.exe" /quiet /norestart
call :check %errorlevel% "SP2" || goto :eof
call :next 2
goto :eof

:stage2
call :install kb968930 "PowerShell 2.0 and WinRM 2.0 (KB968930)" || goto :eof
call :next 3
goto :eof

:stage3
call :install kb4493730 "servicing stack update April 2019 (KB4493730)" || goto :eof
call :next 4
goto :eof

:stage4
call :install kb4474419 "SHA-2 code signing support (KB4474419)" || goto :eof
call :next 5
goto :eof

:stage5
call :install kb4534303 "January 2020 monthly rollup (KB4534303)" || goto :eof
call :next 6
goto :eof

:stage6
call :install kb4536953 "servicing stack update January 2020 (KB4536953)" || goto :eof
call :next 7
goto :eof

:stage7
call :log "QEMU guest agent"
msiexec /i "%SRC%\msi\qemu-ga-x86_64.msi" /qn /norestart /l*v C:\oic\qemu-ga.log
call :check %errorlevel% "QEMU guest agent" || goto :eof
sc config QEMU-GA start= auto >nul

call :log "Cloudbase-Init 0.9.11"
msiexec /i "%SRC%\msi\CloudbaseInitSetup_0_9_11_x64.msi" /qn /norestart /l*v C:\oic\cloudbase-init.log RUN_SERVICE_AS_LOCAL_SYSTEM=1
call :check %errorlevel% "Cloudbase-Init" || goto :eof
set CBI=%ProgramFiles%\Cloudbase Solutions\Cloudbase-Init
copy /y C:\oic\cloudbase-init.conf "%CBI%\conf\cloudbase-init.conf" >nul
copy /y C:\oic\cloudbase-init-unattend.conf "%CBI%\conf\cloudbase-init-unattend.conf" >nul
copy /y C:\oic\Unattend.xml "%CBI%\conf\Unattend.xml" >nul
if not exist "%CBI%\Python\Scripts\cloudbase-init.exe" call :fail "cloudbase-init.exe not found" & goto :eof

call :log "image settings"
rem Remote Desktop, ping, no hibernation, high performance power plan.
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f >nul
netsh advfirewall firewall set rule group="remote desktop" new enable=yes >nul
netsh advfirewall firewall add rule name="ICMPv4 echo request" protocol=icmpv4:8,any dir=in action=allow >nul
powercfg -h off
powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
rem No Server Manager, no Initial Configuration Tasks, no shutdown reason prompt.
reg add "HKLM\SOFTWARE\Microsoft\ServerManager" /v DoNotOpenServerManagerAtLogon /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Microsoft\ServerManager\Oobe" /v DoNotOpenInitialConfigurationTasksAtLogon /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Reliability" /v ShutdownReasonOn /t REG_DWORD /d 0 /f >nul

rem compcln.exe (SP2 component cleanup) is left out: it can ask a question,
rem which would hang a task that has no console.
call :log "cleanup: build logon, setup task, temporary files"
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f >nul
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /f >nul 2>&1
schtasks /delete /tn oic-setup /f >nul
if not exist C:\Windows\Logs mkdir C:\Windows\Logs
copy /y C:\oic\*.log C:\Windows\Logs\ >nul
del /q /f C:\Windows\Temp\*.* >nul 2>&1

call :log "OIC-SETUP-DONE, sysprep /generalize /oobe /shutdown"
rem sysprep runs from a copy outside C:\oic, which it deletes first.
(
echo @echo off
echo rd /s /q C:\oic
echo C:\Windows\System32\sysprep\sysprep.exe /generalize /oobe /shutdown /quiet "/unattend:%CBI%\conf\Unattend.xml"
)> C:\Windows\Temp\oic-sysprep.cmd
start "" /b cmd /c C:\Windows\Temp\oic-sysprep.cmd
goto :eof

rem ---------------------------------------------------------------------
:install
rem %1 file name in updates\ (without .msu), %2 description
call :log "%~2"
wusa.exe "%SRC%\updates\%~1.msu" /quiet /norestart
call :check %errorlevel% "%~2"
exit /b %errorlevel%

:check
rem 0 done, 3010 done and reboot needed, 2359302 already installed.
if "%~1"=="0" exit /b 0
if "%~1"=="3010" exit /b 0
if "%~1"=="2359302" call :log "%~2 already installed" & exit /b 0
call :fail "%~2 failed with exit code %~1"
exit /b 1

:next
(echo %~1)> C:\oic\stage.txt
call :log "reboot, next stage %~1"
shutdown /r /t 10 /d p:4:1 /c "oic-setup"
exit /b 0

:fail
call :log "OIC-SETUP-FAILED: %~1"
shutdown /s /t 30 /d p:4:1 /c "oic-setup failed"
exit /b 0

:log
echo [%date% %time%] oic-setup: %~1>> C:\oic\setup.log
echo [%date% %time%] oic-setup: %~1> COM1
exit /b 0
