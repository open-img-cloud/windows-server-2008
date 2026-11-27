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
for /f "tokens=3*" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CSDVersion 2^>nul ^| find "CSDVersion"') do call :log "service pack: %%a %%b"
if "%SRC%"=="" call :fail "OIC_SETUP CD not found" & goto :eof
rem Let the services (Windows Modules Installer, ...) settle after boot.
ping -n 31 127.0.0.1 >nul
goto stage%STAGE%

:stage1
rem VirtIO drivers other than storage and network (balloon, serial, RNG,
rem pvpanic, SCSI): the publisher is trusted first so that no prompt appears.
rem The network driver waits for stage 7: with a working network, Windows
rem Update and the time service run during the offline installs below, and
rem wusa never returned.
call :log "VirtIO drivers"
rem The drivers chain to VeriSign Class 3 Public Primary CA - G5, which a
rem Windows Server 2008 without Internet access does not have (the root
rem update would download it): without it the packages are seen as unsigned
rem (0x800b010a). Same for the Thawte root of their timestamps.
certutil -addstore -f Root C:\oic\verisign-g5-root.cer >nul
call :check %errorlevel% "VeriSign G5 root" || goto :eof
certutil -addstore -f Root C:\oic\thawte-timestamping-root.cer >nul
call :check %errorlevel% "Thawte timestamping root" || goto :eof
certutil -addstore -f TrustedPublisher C:\oic\redhat.cer >nul
call :check %errorlevel% "Red Hat certificate" || goto :eof
rem pnputil writes to the console only: the errors of setupapi.dev.log
rem (ANSI) go to COM1 instead.
for %%v in (Balloon\balloon vioserial\vioser viorng\viorng pvpanic\pvpanic vioscsi\vioscsi) do (
  pnputil -i -a "%SRC%\drivers\%%v.inf" >nul 2>&1
  call :log "pnputil %%v"
)
findstr /c:"!!!" %windir%\inf\setupapi.dev.log > COM1 2>&1
rem A driver bound to a device can leave a reboot pending, and SP2 then
rem refuses to start (exit code 3017).
call :next 1b
goto :eof

:stage1b
call :log "Windows Server 2008 SP2 (KB948465), the longest step"
"%SRC%\updates\sp2.exe" /quiet /norestart
set RC=%errorlevel%
call :log "SP2: exit code %RC%"
call :check %RC% "SP2" || goto :eof
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
call :log "VirtIO network driver"
pnputil -i -a "%SRC%\drivers\NetKVM\netkvm.inf" >nul 2>&1
findstr /c:"!!!" %windir%\inf\setupapi.dev.log | findstr /i "netkvm" > COM1 2>&1

call :log "QEMU guest agent"
rem The MSI registers the VSS provider (qemu-ga.exe -s vss-install), which
rem fails on Windows Server 2008 (error 1722). The files come from an
rem administrative install instead, which runs no custom action, and the
rem service is created with the arguments of the MSI. No VSS provider:
rem guest-fsfreeze is not available on this image.
msiexec /a "%SRC%\msi\qemu-ga-x86_64.msi" /qn TARGETDIR=C:\oic\qga /l*v C:\oic\qemu-ga.log
set RC=%errorlevel%
if not "%RC%"=="0" call :msilog C:\oic\qemu-ga.log
call :check %RC% "QEMU guest agent files" || goto :eof
set QGA=
for /f "delims=" %%f in ('dir /s /b C:\oic\qga\qemu-ga.exe') do set QGA=%%~dpf
if "%QGA%"=="" call :fail "qemu-ga.exe not found in the MSI" & goto :eof
xcopy /e /i /q /y "%QGA%." "%ProgramFiles%\Qemu-ga" >nul
call :check %errorlevel% "QEMU guest agent copy" || goto :eof
del /q "%ProgramFiles%\Qemu-ga\qga-vss.*" >nul 2>&1
sc create QEMU-GA binPath= "\"%ProgramFiles%\Qemu-ga\qemu-ga.exe\" -d --retry-path" start= auto DisplayName= "QEMU Guest Agent" >nul
call :check %errorlevel% "QEMU guest agent service" || goto :eof
sc description QEMU-GA "QEMU Guest Agent" >nul
rem Diagnostics in the CI log: agent version, service state once started,
rem VirtIO serial driver (the agent channel).
"%ProgramFiles%\Qemu-ga\qemu-ga.exe" -V > COM1 2>&1
call :log "qemu-ga -V exit code %errorlevel%"
sc start QEMU-GA >nul 2>&1
ping -n 11 127.0.0.1 >nul
sc query QEMU-GA > COM1 2>&1
driverquery | findstr /i "vioser netkvm balloon viostor" > COM1 2>&1

call :log "Cloudbase-Init 0.9.11"
msiexec /i "%SRC%\msi\CloudbaseInitSetup_0_9_11_x64.msi" /qn /norestart /l*v C:\oic\cloudbase-init.log RUN_SERVICE_AS_LOCAL_SYSTEM=1
set RC=%errorlevel%
if not "%RC%"=="0" if not "%RC%"=="3010" call :msilog C:\oic\cloudbase-init.log
call :check %RC% "Cloudbase-Init" || goto :eof
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
set RC=%errorlevel%
call :log "%~1: wusa exit code %RC%"
call :check %RC% "%~2"
exit /b %errorlevel%

:check
rem 0 done, 3010 done and reboot needed, 2359302 already installed.
if "%~1"=="0" exit /b 0
if "%~1"=="3010" exit /b 0
if "%~1"=="2359302" call :log "%~2 already installed" & exit /b 0
call :fail "%~2 failed with exit code %~1"
exit /b 1

:msilog
rem Error lines of a Windows Installer log (UTF-16: type converts it), raw
rem to COM1 so that the CI log shows why the package failed.
type "%~1" | findstr /i /c:"return value 3" /c:"error 1" /c:"error 2" /c:"CustomAction" > COM1
exit /b 0

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
