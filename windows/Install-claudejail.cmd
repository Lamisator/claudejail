@echo off
rem claudejail setup for Windows.
rem Double-click this file. It downloads the setup wizard from GitHub and
rem starts it; everything else happens in the wizard window.
rem To install from a different branch, set CLAUDEJAIL_REF before running it.
setlocal
if not defined CLAUDEJAIL_REF set "CLAUDEJAIL_REF=main"
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$ErrorActionPreference='Stop'; try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; $d = Join-Path $env:LOCALAPPDATA 'claudejail\app'; New-Item -ItemType Directory -Force -Path $d | Out-Null; $f = Join-Path $d 'ClaudeJailSetup.ps1'; $u = 'https://raw.githubusercontent.com/lamisator/claudejail/' + $env:CLAUDEJAIL_REF + '/windows/setup/ClaudeJailSetup.ps1'; (New-Object Net.WebClient).DownloadFile($u, $f); & $f -Ref $env:CLAUDEJAIL_REF } catch { Add-Type -AssemblyName System.Windows.Forms; [void][Windows.Forms.MessageBox]::Show('claudejail setup could not start: ' + $_.Exception.Message, 'claudejail setup', 'OK', 'Error') }"
