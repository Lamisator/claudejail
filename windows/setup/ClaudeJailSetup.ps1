<#
  claudejail setup for Windows

  A graphical wizard that sets up everything claudejail needs:
    - WSL 2 (Windows Subsystem for Linux), if missing
    - a dedicated WSL distribution called "claudejail" (Ubuntu 24.04)
    - Docker Engine and the claudejail image inside it
    - Start menu shortcuts and an "Open in claudejail" folder context menu entry

  Start it with Install-claudejail.cmd. The files it needs are downloaded from
  GitHub (https://github.com/<Repo>, branch <Ref>).

  Switches:
    -Ref <branch>   branch to install from (default: main, or the one used before)
    -Resume         continue after the restart that WSL may need
    -Uninstall      remove claudejail

  Windows PowerShell 5.1 compatible. Keep this file ASCII-only: Windows
  PowerShell reads BOM-less scripts in the ANSI code page.
#>
param(
  [string]$Ref,
  [string]$Repo = 'lamisator/claudejail',
  [switch]$Resume,
  [switch]$Uninstall,
  [switch]$NoSelfUpdate
)

$ErrorActionPreference = 'Stop'
$SetupVersion = '1.0.0'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try {
  Add-Type -Namespace CJSetup -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
  [void][CJSetup.Native]::SetProcessDPIAware()
} catch { }
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------------
# Shared code. Runs in the UI thread and, as text, in background runspaces.
# ---------------------------------------------------------------------------
$Core = {
  $DistroName = 'claudejail'
  $AppRoot = Join-Path $env:LOCALAPPDATA 'claudejail'
  $AppDir = Join-Path $AppRoot 'app'
  $DistroDir = Join-Path $AppRoot 'distro'
  $CacheDir = Join-Path $AppRoot 'cache'
  $ConfigPath = Join-Path $AppDir 'config.json'
  $LogPath = Join-Path $AppRoot 'setup.log'
  $WslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'
  $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $ManifestUrl = 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json'
  $UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\claudejail'
  $RunOnceKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
  $ContextMenuKeys = @(
    'HKCU:\Software\Classes\Directory\shell\claudejail',
    'HKCU:\Software\Classes\Directory\Background\shell\claudejail'
  )

  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

  function Write-Log([string]$Message) {
    if ($sync) { $sync.Log.Enqueue($Message) }
  }

  function Join-Args([string[]]$ArgumentList) {
    $parts = foreach ($a in $ArgumentList) {
      if ($null -eq $a -or $a -eq '') { '""' }
      elseif ($a -notmatch '[\s"]') { $a }
      else { '"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
    }
    $parts -join ' '
  }

  # Runs a program without a window, streams stdout to the log, returns
  # ExitCode/Output/Error. StdinText is written to the program's stdin.
  function Invoke-Native {
    param([string]$FilePath, [string[]]$ArgumentList, [string]$StdinText, [switch]$NoLog)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = Join-Args $ArgumentList
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.EnvironmentVariables['WSL_UTF8'] = '1'
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($sync) { $sync.CurrentProcess = $p }
    try {
      $errTask = $p.StandardError.ReadToEndAsync()
      if ($StdinText) {
        $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($StdinText)
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
      }
      $p.StandardInput.Close()
      $out = New-Object System.Text.StringBuilder
      while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
        $line = $line.Replace([string][char]0, '')
        [void]$out.AppendLine($line)
        if (-not $NoLog) { Write-Log $line }
      }
      $p.WaitForExit()
      $err = $errTask.Result.Replace([string][char]0, '')
      if (-not $NoLog) {
        foreach ($l in ($err -split "`r?`n")) { if ($l.Trim()) { Write-Log $l } }
      }
      return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $out.ToString(); Error = $err }
    } finally {
      if ($sync) { $sync.CurrentProcess = $null }
    }
  }

  function Invoke-Wsl {
    param([string[]]$ArgumentList, [string]$StdinText, [switch]$NoLog, [switch]$Check)
    $r = Invoke-Native -FilePath $WslExe -ArgumentList $ArgumentList -StdinText $StdinText -NoLog:$NoLog
    if ($sync -and $sync.Cancel) { throw 'Setup was cancelled.' }
    if ($Check -and $r.ExitCode -ne 0) {
      $msg = ($r.Error + "`n" + $r.Output).Trim()
      if ($msg.Length -gt 600) { $msg = '...' + $msg.Substring($msg.Length - 600) }
      throw "wsl.exe failed (exit code $($r.ExitCode)): $msg"
    }
    return $r
  }

  function Test-WslReady {
    if (-not (Test-Path -LiteralPath $WslExe)) { return $false }
    try { return ((Invoke-Native -FilePath $WslExe -ArgumentList @('--version') -NoLog).ExitCode -eq 0) }
    catch { return $false }
  }

  function Test-DistroRegistered {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path $key)) { return $false }
    foreach ($child in Get-ChildItem $key) {
      $name = (Get-ItemProperty -LiteralPath $child.PSPath -ErrorAction SilentlyContinue).DistributionName
      if ($name -eq $DistroName) { return $true }
    }
    return $false
  }

  function Test-Arm64 {
    return ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64')
  }

  function Get-RawUrl([string]$Repo, [string]$Ref, [string]$Path) {
    return "https://raw.githubusercontent.com/$Repo/$Ref/$Path"
  }

  function Save-Download([string]$Url, [string]$Destination, [string]$Label) {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'claudejail-setup'
    $resp = $req.GetResponse()
    try {
      $total = $resp.ContentLength
      $in = $resp.GetResponseStream()
      $part = "$Destination.part"
      $out = [System.IO.File]::Create($part)
      try {
        $buf = New-Object byte[] (1MB)
        $done = 0L
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
          if ($sync -and $sync.Cancel) { throw 'Setup was cancelled.' }
          $out.Write($buf, 0, $n)
          $done += $n
          if ($sync -and $Label) {
            $mb = [Math]::Round($done / 1MB)
            if ($total -gt 0) {
              $sync.Percent = [int](100 * $done / $total)
              $sync.Detail = "$Label ($mb of $([Math]::Round($total / 1MB)) MB)"
            } else {
              $sync.Detail = "$Label ($mb MB)"
            }
          }
        }
      } finally { $out.Close(); $in.Close() }
    } finally { $resp.Close() }
    Move-Item -LiteralPath $part -Destination $Destination -Force
  }

  function Get-UbuntuImageInfo {
    $json = (New-Object System.Net.WebClient).DownloadString($ManifestUrl) | ConvertFrom-Json
    $entries = @($json.ModernDistributions.Ubuntu)
    $pick = $entries | Where-Object { $_.Name -eq 'Ubuntu-24.04' } | Select-Object -First 1
    if (-not $pick) { $pick = $entries | Where-Object { $_.Default } | Select-Object -First 1 }
    if (-not $pick) { throw 'Could not find an Ubuntu image in the WSL distribution list.' }
    $prop = 'Amd64Url'
    if (Test-Arm64) { $prop = 'Arm64Url' }
    $u = $pick.$prop
    if (-not $u -or -not $u.Url) { throw "No Ubuntu image for this processor ($prop)." }
    return [pscustomobject]@{
      Name   = $pick.FriendlyName
      Url    = $u.Url
      Sha256 = ([string]$u.Sha256 -replace '^0x', '').ToLowerInvariant()
    }
  }

  # Downloads the image (or reuses a verified copy) and names it after its
  # real compression, which wsl --import uses to read it.
  function Get-UbuntuImage($Info) {
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    $base = [IO.Path]::GetFileNameWithoutExtension(([Uri]$Info.Url).AbsolutePath)
    foreach ($ext in '.tar.gz', '.tar.xz', '.tar') {
      $f = Join-Path $CacheDir ($base + $ext)
      if ((Test-Path -LiteralPath $f) -and
          (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Info.Sha256) {
        Write-Log "Using downloaded copy: $f"
        return $f
      }
    }
    $tmp = Join-Path $CacheDir ($base + '.download')
    Save-Download -Url $Info.Url -Destination $tmp -Label 'Downloading'
    $hash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Info.Sha256 -and $hash -ne $Info.Sha256) {
      Remove-Item -LiteralPath $tmp -Force
      throw "The downloaded Ubuntu image is damaged (SHA-256 mismatch). Try again."
    }
    Write-Log "SHA-256 verified: $hash"
    $fs = [IO.File]::OpenRead($tmp)
    try { $magic = New-Object byte[] 6; [void]$fs.Read($magic, 0, 6) } finally { $fs.Close() }
    $ext = '.tar'
    if ($magic[0] -eq 0x1f -and $magic[1] -eq 0x8b) { $ext = '.tar.gz' }
    elseif ($magic[0] -eq 0xfd -and $magic[1] -eq 0x37 -and $magic[2] -eq 0x7a) { $ext = '.tar.xz' }
    $final = Join-Path $CacheDir ($base + $ext)
    Move-Item -LiteralPath $tmp -Destination $final -Force
    return $final
  }

  function Read-Config {
    if (Test-Path -LiteralPath $ConfigPath) {
      try { return (Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json) } catch { }
    }
    return $null
  }

  function New-Shortcut([string]$LinkPath, [string]$Target, [string]$Arguments, [string]$Description, [string]$Icon) {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($LinkPath)
    $lnk.TargetPath = $Target
    $lnk.Arguments = $Arguments
    $lnk.Description = $Description
    $lnk.WorkingDirectory = $env:USERPROFILE
    if ($Icon) { $lnk.IconLocation = $Icon }
    $lnk.Save()
  }

  function Remove-WindowsIntegration {
    foreach ($k in $ContextMenuKeys + @($UninstallKey)) {
      if (Test-Path $k) { Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Remove-ItemProperty -Path $RunOnceKey -Name 'claudejailSetup' -ErrorAction SilentlyContinue
    $startDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'claudejail'
    if (Test-Path -LiteralPath $startDir) { Remove-Item -LiteralPath $startDir -Recurse -Force -ErrorAction SilentlyContinue }
    $desk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'claudejail.lnk'
    if (Test-Path -LiteralPath $desk) { Remove-Item -LiteralPath $desk -Force -ErrorAction SilentlyContinue }
  }

  function Install-WindowsIntegration($Opt) {
    Remove-WindowsIntegration
    $launcher = Join-Path $AppDir 'Launch-ClaudeJail.ps1'
    $setup = Join-Path $AppDir 'ClaudeJailSetup.ps1'
    $psArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File'
    $icon = "$WslExe,0"
    $projects = '\\wsl$\' + $DistroName + '\home\' + $Opt.User + '\projects'

    if ($Opt.ContextMenu) {
      foreach ($k in $ContextMenuKeys) {
        New-Item -Path $k -Force -Value 'Open in claudejail' | Out-Null
        New-ItemProperty -Path $k -Name 'Icon' -Value $icon -PropertyType String -Force | Out-Null
        New-Item -Path "$k\command" -Force -Value ('"' + $PowerShellExe + '" ' + $psArgs + ' "' + $launcher + '" "%V"') | Out-Null
      }
    }
    if ($Opt.StartMenu) {
      $dir = Join-Path ([Environment]::GetFolderPath('Programs')) 'claudejail'
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      New-Shortcut (Join-Path $dir 'claudejail.lnk') $PowerShellExe "$psArgs `"$launcher`"" 'Open a folder in claudejail' $icon
      New-Shortcut (Join-Path $dir 'claudejail projects.lnk') (Join-Path $env:SystemRoot 'explorer.exe') $projects `
        'Projects folder inside the claudejail environment' "$env:SystemRoot\System32\shell32.dll,3"
      if ($Opt.AuthMode -eq 'account') {
        New-Shortcut (Join-Path $dir 'Sign in to Claude.lnk') $PowerShellExe "$psArgs `"$launcher`" -Login" 'Sign in to your Claude account' $icon
      }
      New-Shortcut (Join-Path $dir 'claudejail setup (update or repair).lnk') $PowerShellExe "$psArgs `"$setup`"" 'Update or repair claudejail' $icon
      New-Shortcut (Join-Path $dir 'Uninstall claudejail.lnk') $PowerShellExe "$psArgs `"$setup`" -Uninstall" 'Remove claudejail' $icon
    }
    if ($Opt.Desktop) {
      New-Shortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'claudejail.lnk') $PowerShellExe "$psArgs `"$launcher`"" 'Open a folder in claudejail' $icon
    }

    New-Item -Path $UninstallKey -Force | Out-Null
    $values = @{
      DisplayName     = 'claudejail'
      DisplayVersion  = $SetupVersion
      Publisher       = 'claudejail'
      InstallLocation = $AppRoot
      DisplayIcon     = $icon
      UninstallString = "`"$PowerShellExe`" $psArgs `"$setup`" -Uninstall"
    }
    foreach ($k in $values.Keys) { New-ItemProperty -Path $UninstallKey -Name $k -Value $values[$k] -PropertyType String -Force | Out-Null }
    New-ItemProperty -Path $UninstallKey -Name 'NoModify' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name 'NoRepair' -Value 1 -PropertyType DWord -Force | Out-Null
  }

  # Turns on the Windows features and installs WSL. Needs administrator rights,
  # so it runs in a separate elevated PowerShell. Returns 0, 3010 (restart
  # needed) or another exit code on failure.
  function Install-WslElevated([string]$LogFile) {
    $script = @'
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
$log = '__LOG__'
function L([string]$m) { Add-Content -LiteralPath $log -Value $m }
$restart = $false
try {
  foreach ($f in 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $f).State
    L "$f : $state"
    if ($state -ne 'Enabled') {
      $r = Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart -WarningAction SilentlyContinue
      if ($r.RestartNeeded) { $restart = $true }
      L "$f enabled (restart needed: $($r.RestartNeeded))"
    }
  }
  L (& wsl.exe --install --no-distribution 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0) {
    L (& wsl.exe --update --web-download 2>&1 | Out-String)
  }
} catch {
  L ('ERROR: ' + $_.Exception.Message)
  exit 1
}
if ($restart) { exit 3010 }
exit 0
'@
    $script = $script.Replace('__LOG__', $LogFile.Replace("'", "''"))
    if (Test-Path -LiteralPath $LogFile) { Remove-Item -LiteralPath $LogFile -Force }
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    Write-Log 'Asking Windows for administrator permission...'
    $p = Start-Process -FilePath $PowerShellExe -Verb RunAs -WindowStyle Hidden -Wait -PassThru `
      -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
    if (Test-Path -LiteralPath $LogFile) {
      foreach ($l in Get-Content -LiteralPath $LogFile) { if ($l.Trim()) { Write-Log $l } }
    }
    return $p.ExitCode
  }
}

$sync = [hashtable]::Synchronized(@{
  Log            = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
  StepText       = ''
  Detail         = ''
  Percent        = -1
  Cancel         = $false
  CurrentProcess = $null
  Error          = $null
  Result         = $null
})
. $Core

function Show-Message([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK') {
  return [System.Windows.Forms.MessageBox]::Show($Text, 'claudejail setup',
    [System.Windows.Forms.MessageBoxButtons]$Buttons, [System.Windows.Forms.MessageBoxIcon]$Icon)
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if ($Uninstall) {
  $cfg = Read-Config
  $projects = '\\wsl$\claudejail\home\<user>\projects'
  if ($cfg) { $projects = '\\wsl$\claudejail\home\' + $cfg.User + '\projects' }
  $answer = Show-Message ("This removes claudejail from this computer:`n`n" +
    "- the claudejail Linux environment, including everything stored in it, such as the projects folder ($projects) and your Claude sign-in there`n" +
    "- the Docker image, shortcuts and the Explorer menu entry`n`n" +
    "Folders on your Windows drives that you opened with claudejail are not touched. WSL itself stays installed.`n`n" +
    'Remove claudejail?') 'Warning' 'YesNo'
  if ($answer -ne 'Yes') { exit 0 }
  try {
    if (Test-DistroRegistered) {
      [void](Invoke-Native -FilePath $WslExe -ArgumentList @('--terminate', $DistroName) -NoLog)
      $r = Invoke-Native -FilePath $WslExe -ArgumentList @('--unregister', $DistroName) -NoLog
      if ($r.ExitCode -ne 0) { throw ('wsl --unregister failed: ' + ($r.Error + $r.Output).Trim()) }
    }
    Remove-WindowsIntegration
  } catch {
    [void](Show-Message ('claudejail could not be removed completely: ' + $_.Exception.Message) 'Error')
    exit 1
  }
  # This script lives in $AppRoot; delete the folder once it has exited.
  Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -WindowStyle Hidden -WorkingDirectory $env:TEMP `
    -ArgumentList "/c timeout /t 3 /nobreak >nul & rmdir /s /q `"$AppRoot`""
  [void](Show-Message 'claudejail has been removed.')
  exit 0
}

# ---------------------------------------------------------------------------
# Fetch the setup files from GitHub
# ---------------------------------------------------------------------------
$existingConfig = Read-Config
if (-not $Ref) {
  if ($env:CLAUDEJAIL_REF) { $Ref = $env:CLAUDEJAIL_REF }
  elseif ($existingConfig -and $existingConfig.Ref) { $Ref = $existingConfig.Ref }
  else { $Ref = 'main' }
}
if ($existingConfig -and $existingConfig.Repo -and -not $PSBoundParameters.ContainsKey('Repo')) {
  $Repo = $existingConfig.Repo
}
if ($Ref -notmatch '^[A-Za-z0-9_./-]+$' -or $Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
  [void](Show-Message "Invalid repository or branch: $Repo @ $Ref" 'Error')
  exit 1
}

$SetupFiles = @('ClaudeJailSetup.ps1', 'Launch-ClaudeJail.ps1', 'provision.sh')
try {
  New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
  $self = $null
  if ($PSCommandPath) { $self = [IO.Path]::GetFullPath($PSCommandPath) }
  foreach ($name in $SetupFiles) {
    $dest = Join-Path $AppDir $name
    $url = Get-RawUrl $Repo $Ref "windows/setup/$name"
    if ($name -eq 'ClaudeJailSetup.ps1' -and $self -and $self -ieq [IO.Path]::GetFullPath($dest)) {
      # Running the installed copy (Start menu, restart): replace it if GitHub
      # has a newer version, then start the new one.
      if ($NoSelfUpdate) { continue }
      Save-Download -Url $url -Destination "$dest.new"
      if ((Get-FileHash -LiteralPath "$dest.new").Hash -ne (Get-FileHash -LiteralPath $dest).Hash) {
        Move-Item -LiteralPath "$dest.new" -Destination $dest -Force
        $relaunch = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest`" -NoSelfUpdate -Ref $Ref -Repo $Repo"
        if ($Resume) { $relaunch += ' -Resume' }
        Start-Process -FilePath $PowerShellExe -ArgumentList $relaunch
        exit 0
      }
      Remove-Item -LiteralPath "$dest.new" -Force
      continue
    }
    Save-Download -Url $url -Destination $dest
  }
} catch {
  [void](Show-Message ("Could not download the setup files from GitHub ($Repo, branch $Ref).`n`n" +
    $_.Exception.Message + "`n`nCheck your internet connection and try again.") 'Error')
  exit 1
}

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------
$g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$S = $g.DpiX / 96.0
$g.Dispose()
function Px([double]$v) { return [int][Math]::Round($v * $S) }

$fontBase = New-Object System.Drawing.Font('Segoe UI', 9)
$fontBold = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$fontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
$fontMono = New-Object System.Drawing.Font('Consolas', 8.5)
$colMuted = [System.Drawing.Color]::FromArgb(90, 98, 108)
$colOk = [System.Drawing.Color]::FromArgb(16, 124, 16)
$colWarn = [System.Drawing.Color]::FromArgb(157, 93, 0)
$colErr = [System.Drawing.Color]::FromArgb(196, 43, 28)
$W = Px 680   # wrap width for text

$CHECK = [string][char]0x2714
$WARN = [string][char]0x26A0
$CROSS = [string][char]0x2716

function New-Label([string]$Text, [switch]$Bold, $Color = $null, [int]$Top = 0, [int]$Bottom = 6) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $Text
  $l.AutoSize = $true
  $l.UseMnemonic = $false
  $l.MaximumSize = New-Object System.Drawing.Size($W, 0)
  if ($Bold) { $l.Font = $fontBold }
  if ($Color) { $l.ForeColor = $Color }
  $l.Margin = New-Object System.Windows.Forms.Padding(0, (Px $Top), 0, (Px $Bottom))
  return $l
}

function New-Button([string]$Text, [int]$Width = 0) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $Text
  $b.AutoSize = $true
  $b.AutoSizeMode = 'GrowOnly'
  $b.MinimumSize = New-Object System.Drawing.Size((Px ([Math]::Max($Width, 100))), (Px 28))
  $b.Margin = New-Object System.Windows.Forms.Padding(0, (Px 2), (Px 8), (Px 6))
  return $b
}

function New-Row {
  $f = New-Object System.Windows.Forms.FlowLayoutPanel
  $f.FlowDirection = 'LeftToRight'
  $f.AutoSize = $true
  $f.WrapContents = $false
  $f.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (Px 4))
  return $f
}

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------
$state = @{ Page = $null; History = New-Object System.Collections.ArrayList; Worker = $null
  WslReady = $false; Blocking = $false; Existing = $false; Opt = $null; InstallFailed = $false
  Pages = @{}; LoginPending = $false; CloseConfirmed = $false }
$ui = @{}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'claudejail setup'
$form.Font = $fontBase
$form.AutoScaleMode = 'None'
$form.ClientSize = New-Object System.Drawing.Size((Px 760), (Px 600))
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.SystemColors]::Window
try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($WslExe) } catch { }

$content = New-Object System.Windows.Forms.Panel
$content.Dock = 'Fill'
$content.Padding = New-Object System.Windows.Forms.Padding((Px 28), (Px 18), (Px 20), (Px 8))

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = Px 72
$header.BackColor = [System.Drawing.Color]::FromArgb(243, 245, 248)
$ui.Title = New-Object System.Windows.Forms.Label
$ui.Title.Font = $fontTitle
$ui.Title.AutoSize = $true
$ui.Title.Location = New-Object System.Drawing.Point((Px 26), (Px 12))
$ui.Subtitle = New-Object System.Windows.Forms.Label
$ui.Subtitle.AutoSize = $true
$ui.Subtitle.ForeColor = $colMuted
$ui.Subtitle.Location = New-Object System.Drawing.Point((Px 28), (Px 44))
$header.Controls.Add($ui.Title)
$header.Controls.Add($ui.Subtitle)

$sepTop = New-Object System.Windows.Forms.Panel
$sepTop.Dock = 'Top'; $sepTop.Height = 1; $sepTop.BackColor = [System.Drawing.Color]::FromArgb(218, 222, 228)
$sepBottom = New-Object System.Windows.Forms.Panel
$sepBottom.Dock = 'Bottom'; $sepBottom.Height = 1; $sepBottom.BackColor = $sepTop.BackColor

$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = 'Bottom'
$footer.Height = Px 54
$footer.BackColor = $header.BackColor
$ui.Back = New-Button '< Back' 90
$ui.Next = New-Button 'Next >' 90
$ui.Cancel = New-Button 'Cancel' 90
$buttonRow = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonRow.FlowDirection = 'RightToLeft'
$buttonRow.Dock = 'Fill'
$buttonRow.Padding = New-Object System.Windows.Forms.Padding((Px 12), (Px 12), (Px 16), 0)
$buttonRow.Controls.Add($ui.Cancel)
$buttonRow.Controls.Add($ui.Next)
$buttonRow.Controls.Add($ui.Back)
$ui.Cancel.Margin = New-Object System.Windows.Forms.Padding((Px 14), 0, 0, 0)
$ui.Next.Margin = New-Object System.Windows.Forms.Padding((Px 6), 0, 0, 0)
$ui.Back.Margin = New-Object System.Windows.Forms.Padding(0)
$footer.Controls.Add($buttonRow)

# Docking runs from the last-added control backwards: add Fill first.
$form.Controls.Add($content)
$form.Controls.Add($sepTop)
$form.Controls.Add($sepBottom)
$form.Controls.Add($header)
$form.Controls.Add($footer)
$form.AcceptButton = $ui.Next

function New-Page([string]$Name, [string]$Title, [string]$Subtitle) {
  $flow = New-Object System.Windows.Forms.FlowLayoutPanel
  $flow.FlowDirection = 'TopDown'
  $flow.WrapContents = $false
  $flow.AutoScroll = $true
  $flow.Dock = 'Fill'
  $flow.Visible = $false
  $content.Controls.Add($flow)
  $page = @{ Name = $Name; Title = $Title; Subtitle = $Subtitle; Flow = $flow
    OnEnter = $null; OnNext = $null; NextText = 'Next >'; CanBack = $true }
  $state.Pages[$Name] = $page
  return $page
}

function Show-Page([string]$Name, [switch]$NoHistory) {
  if ($state.Page -and -not $NoHistory) { [void]$state.History.Add($state.Page) }
  foreach ($p in $state.Pages.Values) { $p.Flow.Visible = $false }
  $page = $state.Pages[$Name]
  $state.Page = $Name
  $ui.Title.Text = $page.Title
  $ui.Subtitle.Text = $page.Subtitle
  $ui.Next.Text = $page.NextText
  $ui.Next.Enabled = $true
  $ui.Back.Enabled = ($page.CanBack -and $state.History.Count -gt 0)
  $page.Flow.Visible = $true
  if ($page.OnEnter) { & $page.OnEnter }
}

function Start-Worker([scriptblock]$Body, [hashtable]$Vars, [scriptblock]$OnDone) {
  $sync.Error = $null
  $sync.Result = $null
  $sync.Cancel = $false
  $rs = [runspacefactory]::CreateRunspace()
  $rs.ApartmentState = 'STA'
  $rs.Open()
  $rs.SessionStateProxy.SetVariable('sync', $sync)
  $rs.SessionStateProxy.SetVariable('SetupVersion', $SetupVersion)
  if ($Vars) { foreach ($k in $Vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $Vars[$k]) } }
  $ps = [powershell]::Create()
  $ps.Runspace = $rs
  $code = "`$ErrorActionPreference = 'Stop'`n" + $Core.ToString() + "`ntry {`n" + $Body.ToString() +
    "`n} catch { `$sync.Error = `$_.Exception.Message; Write-Log ('ERROR: ' + `$_.Exception.Message) }"
  [void]$ps.AddScript($code)
  $state.Worker = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); OnDone = $OnDone }
}

# ---------------------------------------------------------------------------
# Page 1: welcome and system check
# ---------------------------------------------------------------------------
$p = New-Page 'welcome' 'Welcome to claudejail setup' 'Run Claude Code in a Docker sandbox on Windows'
$p.Flow.Controls.Add((New-Label ("This wizard sets up everything claudejail needs. You won't have to type any commands.")))
$p.Flow.Controls.Add((New-Label ("  -  Windows Subsystem for Linux (WSL 2), if it isn't installed yet`n" +
  "  -  a separate Linux environment called `"claudejail`" (Ubuntu 24.04), so other WSL distributions stay untouched`n" +
  "  -  Docker Engine and the claudejail sandbox image inside it`n" +
  "  -  Start menu shortcuts and an `"Open in claudejail`" entry when you right-click a folder") -Bottom 8))
$p.Flow.Controls.Add((New-Label ("Setup downloads about 1.5 GB from Microsoft, Ubuntu, Docker, GitHub and Anthropic " +
  "and usually takes 10 to 20 minutes. Files come from github.com/$Repo (branch $Ref).") -Color $colMuted -Bottom 12))
$p.Flow.Controls.Add((New-Label 'System check' -Bold -Top 4))
$ui.Checks = New-Object System.Windows.Forms.FlowLayoutPanel
$ui.Checks.FlowDirection = 'TopDown'
$ui.Checks.AutoSize = $true
$ui.Checks.WrapContents = $false
$p.Flow.Controls.Add($ui.Checks)

function Add-Check([string]$Kind, [string]$Text) {
  $sym = $CHECK; $col = $colOk
  if ($Kind -eq 'warn') { $sym = $WARN; $col = $colWarn }
  if ($Kind -eq 'fail') { $sym = $CROSS; $col = $colErr; $state.Blocking = $true }
  $row = New-Row
  $icon = New-Label $sym -Color $col -Bottom 2
  $icon.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 9)
  $icon.MinimumSize = New-Object System.Drawing.Size((Px 22), 0)
  $txt = New-Label $Text -Bottom 2
  $txt.MaximumSize = New-Object System.Drawing.Size(($W - (Px 26)), 0)
  $row.Controls.Add($icon)
  $row.Controls.Add($txt)
  $ui.Checks.Controls.Add($row)
}

function Invoke-SystemCheck {
  $ui.Checks.Controls.Clear()
  $state.Blocking = $false
  $build = [Environment]::OSVersion.Version.Build
  if (-not [Environment]::Is64BitOperatingSystem) {
    Add-Check 'fail' 'Windows is 32-bit. WSL 2 needs 64-bit Windows.'
  } elseif ($build -lt 19041) {
    Add-Check 'fail' "Windows build $build is too old. WSL 2 needs Windows 10 version 2004 (build 19041) or newer; install Windows updates first."
  } elseif ($build -lt 19045) {
    Add-Check 'warn' "Windows build $build works, but Windows 10 22H2 or Windows 11 is recommended."
  } else {
    Add-Check 'ok' "Windows build $build"
  }

  try {
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    if ($cs.HypervisorPresent) {
      Add-Check 'ok' 'Virtualization is available'
    } elseif ($cpu.VirtualizationFirmwareEnabled) {
      Add-Check 'ok' 'Virtualization is enabled in the firmware'
    } else {
      Add-Check 'fail' ("Hardware virtualization is turned off. Turn on Intel VT-x / AMD-V (sometimes called SVM) " +
        'in your computer''s BIOS/UEFI settings, then run setup again.')
    }
  } catch {
    Add-Check 'warn' 'Could not check whether virtualization is enabled.'
  }

  try {
    $drive = New-Object System.IO.DriveInfo ([IO.Path]::GetPathRoot($env:LOCALAPPDATA))
    $freeGb = [Math]::Round($drive.AvailableFreeSpace / 1GB)
    if ($freeGb -lt 8) { Add-Check 'warn' "Only $freeGb GB free on $($drive.Name). claudejail needs at least 8 GB." }
    else { Add-Check 'ok' "$freeGb GB free on $($drive.Name)" }
  } catch { }

  $state.WslReady = Test-WslReady
  if ($state.WslReady) { Add-Check 'ok' 'WSL is installed' }
  else { Add-Check 'warn' 'WSL is not installed yet. Setup will install it (administrator permission needed, possibly a restart).' }

  $state.Existing = Test-DistroRegistered
  if ($state.Existing) {
    Add-Check 'ok' 'claudejail is already installed. Setup will update it and keep your files.'
  }
}

$p.OnEnter = {
  Invoke-SystemCheck
  if ($state.Blocking) {
    $ui.Next.Enabled = $false
    $ui.Cancel.Text = 'Close'
  }
}
$p.OnNext = {
  if ($state.WslReady) { return 'options' }
  return 'wsl'
}

# ---------------------------------------------------------------------------
# Page 2: install WSL
# ---------------------------------------------------------------------------
$p = New-Page 'wsl' 'Install WSL' 'Windows Subsystem for Linux runs the claudejail environment'
$p.Flow.Controls.Add((New-Label ("Setup turns on the Windows features WSL needs and installs WSL from Microsoft. " +
  'Windows asks for administrator permission once.') -Bottom 12))
$ui.WslInstall = New-Button 'Install WSL' 140
$p.Flow.Controls.Add($ui.WslInstall)
$ui.WslStatus = New-Label '' -Top 6
$p.Flow.Controls.Add($ui.WslStatus)
$ui.WslRestart = New-Button 'Restart now' 140
$ui.WslRestart.Visible = $false
$p.Flow.Controls.Add($ui.WslRestart)

$p.OnEnter = {
  $ui.Next.Enabled = $state.WslReady
}

function Set-ResumeAfterRestart {
  $cmd = '"' + $PowerShellExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
    (Join-Path $AppDir 'ClaudeJailSetup.ps1') + '" -Resume -Ref ' + $Ref
  New-ItemProperty -Path $RunOnceKey -Name 'claudejailSetup' -Value $cmd -PropertyType String -Force | Out-Null
}

$ui.WslInstall.Add_Click({
  $ui.WslInstall.Enabled = $false
  $ui.Next.Enabled = $false
  $ui.Back.Enabled = $false
  $ui.WslStatus.ForeColor = $form.ForeColor
  $ui.WslStatus.Text = 'Installing WSL. Approve the administrator prompt; this can take a few minutes...'
  Start-Worker -Body {
    $sync.Result = Install-WslElevated -LogFile (Join-Path $env:TEMP 'claudejail-wsl-install.log')
  } -OnDone {
    $ui.Back.Enabled = $true
    if ($sync.Error) {
      $msg = $sync.Error
      if ($msg -match 'canceled|cancelled') { $msg = 'The administrator prompt was declined.' }
      $ui.WslStatus.ForeColor = $colErr
      $ui.WslStatus.Text = "WSL was not installed: $msg"
      $ui.WslInstall.Enabled = $true
      return
    }
    $code = $sync.Result
    $state.WslReady = Test-WslReady
    if ($code -eq 3010 -or ($code -eq 0 -and -not $state.WslReady)) {
      Set-ResumeAfterRestart
      $ui.WslStatus.ForeColor = $colWarn
      $ui.WslStatus.Text = ('Windows needs to restart to finish installing WSL. Setup opens again by itself ' +
        'after you sign back in. Save your work in other programs first.')
      $ui.WslRestart.Visible = $true
    } elseif ($code -eq 0) {
      $ui.WslStatus.ForeColor = $colOk
      $ui.WslStatus.Text = "$CHECK  WSL is installed. Click Next."
      $ui.Next.Enabled = $true
    } else {
      $ui.WslStatus.ForeColor = $colErr
      $ui.WslStatus.Text = "WSL could not be installed (exit code $code). Details are in $LogPath."
      $ui.WslInstall.Enabled = $true
    }
  }
})

$ui.WslRestart.Add_Click({
  $state.CloseConfirmed = $true
  Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\shutdown.exe') -ArgumentList '/r /t 5 /c "Restarting to finish installing WSL for claudejail"' -WindowStyle Hidden
  $form.Close()
})

$p.OnNext = { return 'options' }

# ---------------------------------------------------------------------------
# Page 3: options
# ---------------------------------------------------------------------------
$p = New-Page 'options' 'Settings' 'Choose how claudejail is set up'

$p.Flow.Controls.Add((New-Label 'Linux user name' -Bold))
$ui.User = New-Object System.Windows.Forms.TextBox
$ui.User.Width = Px 240
$ui.User.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (Px 2))
$p.Flow.Controls.Add($ui.User)
$ui.UserHint = New-Label 'Only used inside the claudejail environment. Lowercase letters, digits, - and _.' -Color $colMuted -Bottom 12
$p.Flow.Controls.Add($ui.UserHint)

$p.Flow.Controls.Add((New-Label 'How should Claude sign in?' -Bold))
$ui.AuthAccount = New-Object System.Windows.Forms.RadioButton
$ui.AuthAccount.Text = 'With my Claude account (Pro or Max). You sign in through your browser at the end of setup.'
$ui.AuthAccount.AutoSize = $true
$ui.AuthAccount.MaximumSize = New-Object System.Drawing.Size($W, 0)
$ui.AuthKey = New-Object System.Windows.Forms.RadioButton
$ui.AuthKey.Text = 'With an Anthropic API key'
$ui.AuthKey.AutoSize = $true
$authBox = New-Object System.Windows.Forms.FlowLayoutPanel
$authBox.FlowDirection = 'TopDown'; $authBox.AutoSize = $true; $authBox.WrapContents = $false
$authBox.Controls.Add($ui.AuthAccount)
$authBox.Controls.Add($ui.AuthKey)
$ui.ApiKey = New-Object System.Windows.Forms.TextBox
$ui.ApiKey.UseSystemPasswordChar = $true
$ui.ApiKey.Width = Px 420
$ui.ApiKey.Margin = New-Object System.Windows.Forms.Padding((Px 18), 0, 0, (Px 2))
$authBox.Controls.Add($ui.ApiKey)
$ui.ApiKeyHint = New-Label 'The key is stored in the claudejail environment (readable only by your Linux user).' -Color $colMuted
$ui.ApiKeyHint.Margin = New-Object System.Windows.Forms.Padding((Px 18), 0, 0, (Px 12))
$authBox.Controls.Add($ui.ApiKeyHint)
$p.Flow.Controls.Add($authBox)
$updateAuth = { $ui.ApiKey.Enabled = $ui.AuthKey.Checked; $ui.ApiKeyHint.Enabled = $ui.AuthKey.Checked }
$ui.AuthAccount.Add_CheckedChanged($updateAuth)
$ui.AuthKey.Add_CheckedChanged($updateAuth)

$p.Flow.Controls.Add((New-Label 'SSH key for git (optional)' -Bold))
$ui.SshKey = New-Object System.Windows.Forms.ComboBox
$ui.SshKey.DropDownStyle = 'DropDownList'
$ui.SshKey.Width = Px 300
$p.Flow.Controls.Add($ui.SshKey)
$p.Flow.Controls.Add((New-Label ("Lets Claude push and pull over SSH. The key is copied into the claudejail environment; " +
  'each session hands it to the sandbox through an ssh-agent, so the sandbox can use the key but not read it.') -Color $colMuted -Bottom 12))

$p.Flow.Controls.Add((New-Label 'Shortcuts' -Bold))
$ui.OptContext = New-Object System.Windows.Forms.CheckBox
$ui.OptContext.Text = 'Add "Open in claudejail" when right-clicking a folder in Explorer'
$ui.OptStart = New-Object System.Windows.Forms.CheckBox
$ui.OptStart.Text = 'Add claudejail to the Start menu'
$ui.OptDesktop = New-Object System.Windows.Forms.CheckBox
$ui.OptDesktop.Text = 'Add a desktop shortcut'
foreach ($c in $ui.OptContext, $ui.OptStart, $ui.OptDesktop) {
  $c.AutoSize = $true
  $c.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (Px 2))
  $p.Flow.Controls.Add($c)
}
$p.Flow.Controls.Add((New-Label "Installs to $AppRoot" -Color $colMuted -Top 10))

$p.OnEnter = {
  if ($state.OptionsLoaded) { return }
  $state.OptionsLoaded = $true
  $cfg = $existingConfig
  $default = ($env:USERNAME.ToLowerInvariant() -replace '[^a-z0-9_-]', '')
  if ($default -notmatch '^[a-z_]') { $default = 'u' + $default }
  if ($default.Length -gt 32) { $default = $default.Substring(0, 32) }
  if ($default -eq 'root' -or $default.Length -lt 2) { $default = 'claude' }
  $ui.User.Text = $default
  $ui.AuthAccount.Checked = $true
  $ui.OptContext.Checked = $true
  $ui.OptStart.Checked = $true
  $ui.OptDesktop.Checked = $false

  $ui.SshKey.Items.Clear()
  [void]$ui.SshKey.Items.Add('(none)')
  $sshDir = Join-Path $env:USERPROFILE '.ssh'
  if (Test-Path -LiteralPath $sshDir) {
    Get-ChildItem -LiteralPath $sshDir -File | Where-Object {
      $_.Extension -ne '.pub' -and $_.Name -match '^[A-Za-z0-9._-]+$' -and (Test-Path -LiteralPath ($_.FullName + '.pub'))
    } | ForEach-Object { [void]$ui.SshKey.Items.Add($_.Name) }
  }
  $ui.SshKey.SelectedIndex = 0

  if ($state.Existing -and $cfg) {
    $ui.User.Text = $cfg.User
    $ui.User.Enabled = $false
    $ui.UserHint.Text = 'The existing claudejail environment keeps its user.'
    if ($cfg.AuthMode -eq 'apikey') {
      $ui.AuthKey.Checked = $true
      $ui.ApiKeyHint.Text = 'Leave empty to keep the key you entered before.'
    }
    if ($cfg.SshKey -and $ui.SshKey.Items.Contains($cfg.SshKey)) { $ui.SshKey.SelectedItem = $cfg.SshKey }
    $ui.OptContext.Checked = [bool]$cfg.ContextMenu
    $ui.OptStart.Checked = [bool]$cfg.StartMenu
    $ui.OptDesktop.Checked = [bool]$cfg.Desktop
  }
  & $updateAuth
}

$p.OnNext = {
  $user = $ui.User.Text.Trim()
  if ($user -notmatch '^[a-z_][a-z0-9_-]{0,31}$' -or $user -eq 'root') {
    [void](Show-Message 'The Linux user name must start with a lowercase letter or _, and contain only lowercase letters, digits, - and _ (at most 32 characters).' 'Warning')
    return $null
  }
  $key = $ui.ApiKey.Text.Trim()
  $mode = 'account'
  if ($ui.AuthKey.Checked) {
    $mode = 'apikey'
    $keepOld = $state.Existing -and $existingConfig -and $existingConfig.AuthMode -eq 'apikey' -and -not $key
    if (-not $keepOld -and $key -notmatch '^[A-Za-z0-9_-]{20,}$') {
      [void](Show-Message 'Enter your Anthropic API key (it starts with sk-ant-).' 'Warning')
      return $null
    }
  }
  $ssh = $null
  if ($ui.SshKey.SelectedIndex -gt 0) { $ssh = [string]$ui.SshKey.SelectedItem }
  $state.Opt = @{
    User = $user; AuthMode = $mode; ApiKey = $key; SshKey = $ssh
    ContextMenu = $ui.OptContext.Checked; StartMenu = $ui.OptStart.Checked; Desktop = $ui.OptDesktop.Checked
    Repo = $Repo; Ref = $Ref
  }
  return 'install'
}

# ---------------------------------------------------------------------------
# Page 4: install
# ---------------------------------------------------------------------------
$p = New-Page 'install' 'Setting up claudejail' 'You can keep using your computer while this runs'
$p.CanBack = $false
$ui.Step = New-Label 'Starting...' -Bold
$p.Flow.Controls.Add($ui.Step)
$ui.Progress = New-Object System.Windows.Forms.ProgressBar
$ui.Progress.Width = $W
$ui.Progress.Height = Px 18
$ui.Progress.Margin = New-Object System.Windows.Forms.Padding(0, (Px 2), 0, (Px 10))
$p.Flow.Controls.Add($ui.Progress)
$ui.Log = New-Object System.Windows.Forms.TextBox
$ui.Log.Multiline = $true
$ui.Log.ReadOnly = $true
$ui.Log.ScrollBars = 'Vertical'
$ui.Log.WordWrap = $false
$ui.Log.Font = $fontMono
$ui.Log.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 251)
$ui.Log.Width = $W
$ui.Log.Height = Px 300
$p.Flow.Controls.Add($ui.Log)
$ui.InstallError = New-Label '' -Color $colErr -Top 8
$p.Flow.Controls.Add($ui.InstallError)

$InstallBody = {
  function Step([string]$Text) {
    if ($sync.Cancel) { throw 'Setup was cancelled.' }
    $sync.StepIndex++
    $sync.StepText = "Step $($sync.StepIndex) of $($sync.StepCount): $Text"
    $sync.Detail = ''
    $sync.Percent = -1
    Write-Log ''
    Write-Log "=== $Text ==="
  }
  $user = $Opt.User
  $linuxHome = "/home/$user"
  $existing = Test-DistroRegistered
  $sync.StepIndex = 0
  $sync.StepCount = 6
  if (-not $existing) { $sync.StepCount = 8 }
  Write-Log "claudejail setup $SetupVersion - $($Opt.Repo) @ $($Opt.Ref)"

  if (-not $existing) {
    Step 'Downloading Ubuntu 24.04'
    $info = Get-UbuntuImageInfo
    Write-Log "$($info.Name): $($info.Url)"
    $image = Get-UbuntuImage $info

    Step 'Creating the claudejail Linux environment'
    New-Item -ItemType Directory -Force -Path $DistroDir | Out-Null
    [void](Invoke-Wsl -Check -ArgumentList @('--import', $DistroName, $DistroDir, $image, '--version', '2'))
    Remove-Item -LiteralPath $image -Force -ErrorAction SilentlyContinue
  }

  Step 'Copying the setup script into the environment'
  [void](Invoke-Wsl -Check -ArgumentList @('-d', $DistroName, '-u', 'root', '--exec', 'mkdir', '-p', '/opt/claudejail-setup'))
  $text = [IO.File]::ReadAllText((Join-Path $AppDir 'provision.sh')).Replace("`r`n", "`n")
  [void](Invoke-Wsl -Check -NoLog -StdinText $text -ArgumentList @('-d', $DistroName, '-u', 'root', '--exec', 'tee', '/opt/claudejail-setup/provision.sh'))

  Step 'Installing Docker, Claude Code and claudejail (takes a few minutes)'
  [void](Invoke-Wsl -Check -ArgumentList @('-d', $DistroName, '-u', 'root', '--exec', 'env',
    "CJ_USER=$user", "CJ_REPO=$($Opt.Repo)", "CJ_REF=$($Opt.Ref)", 'bash', '/opt/claudejail-setup/provision.sh'))

  Step 'Applying your settings'
  $envFile = "$linuxHome/claudejail/.env"
  if ($Opt.AuthMode -eq 'apikey') {
    if ($Opt.ApiKey) {
      [void](Invoke-Wsl -Check -NoLog -StdinText ("ANTHROPIC_API_KEY=$($Opt.ApiKey)`n") -ArgumentList @('-d', $DistroName, '-u', $user, '--exec', 'tee', $envFile))
      [void](Invoke-Wsl -Check -ArgumentList @('-d', $DistroName, '-u', $user, '--exec', 'chmod', '600', $envFile))
      Write-Log 'API key saved.'
    }
  } else {
    [void](Invoke-Wsl -Check -ArgumentList @('-d', $DistroName, '-u', $user, '--exec', 'rm', '-f', $envFile))
  }
  if ($Opt.SshKey) {
    $src = Join-Path (Join-Path $env:USERPROFILE '.ssh') $Opt.SshKey
    foreach ($pair in @(@($src, $Opt.SshKey, '600'), @("$src.pub", "$($Opt.SshKey).pub", '644'))) {
      $t = [IO.File]::ReadAllText($pair[0]).Replace("`r`n", "`n")
      if (-not $t.EndsWith("`n")) { $t += "`n" }
      $dest = "$linuxHome/.ssh/$($pair[1])"
      [void](Invoke-Wsl -Check -NoLog -StdinText $t -ArgumentList @('-d', $DistroName, '-u', $user, '--exec', 'tee', $dest))
      [void](Invoke-Wsl -Check -ArgumentList @('-d', $DistroName, '-u', $user, '--exec', 'chmod', $pair[2], $dest))
    }
    Write-Log "SSH key $($Opt.SshKey) copied."
  }

  Step 'Restarting the environment'
  [void](Invoke-Wsl -ArgumentList @('--terminate', $DistroName))

  Step 'Building the claudejail image (takes a few minutes)'
  $buildArgs = @('-d', $DistroName, '-u', $user, '--exec', 'bash', "$linuxHome/claudejail/windows/setup/build-image.sh")
  if ($existing) { $buildArgs += 'update' }
  [void](Invoke-Wsl -Check -ArgumentList $buildArgs)

  Step 'Adding Windows shortcuts'
  $cfg = [ordered]@{
    Distro = $DistroName; User = $user; AuthMode = $Opt.AuthMode; SshKey = $Opt.SshKey
    ContextMenu = $Opt.ContextMenu; StartMenu = $Opt.StartMenu; Desktop = $Opt.Desktop
    Repo = $Opt.Repo; Ref = $Opt.Ref; SetupVersion = $SetupVersion
  }
  [IO.File]::WriteAllText($ConfigPath, ($cfg | ConvertTo-Json))
  Install-WindowsIntegration $Opt
  Write-Log ''
  Write-Log 'claudejail is ready.'
  $sync.Percent = 100
  $sync.Detail = ''
  $sync.StepText = 'Finished'
}

$p.OnEnter = {
  $state.InstallFailed = $false
  $ui.InstallError.Text = ''
  $ui.Next.Enabled = $false
  $ui.Back.Enabled = $false
  $ui.Step.Text = 'Starting...'
  $sync.StepText = 'Starting...'
  $sync.Detail = ''
  $sync.Percent = -1
  Start-Worker -Body $InstallBody -Vars @{ Opt = $state.Opt } -OnDone {
    if ($sync.Error) {
      $state.InstallFailed = $true
      $ui.Progress.Style = 'Continuous'
      $ui.Progress.Value = 0
      $ui.InstallError.Text = ("Setup didn't finish: $($sync.Error)`n`nThe full log is in $LogPath. " +
        'Click Retry to try again; steps that already finished are skipped or repeated safely.')
      $ui.Next.Text = 'Retry'
      $ui.Next.Enabled = $true
      $ui.Back.Enabled = $true
    } else {
      Show-Page 'finish' -NoHistory
    }
  }
}
$p.OnNext = {
  if ($state.InstallFailed) { & $state.Pages['install'].OnEnter }
  return $null
}

# ---------------------------------------------------------------------------
# Page 5: finish
# ---------------------------------------------------------------------------
$p = New-Page 'finish' 'claudejail is ready' 'Claude Code now runs in a sandbox on this computer'
$p.CanBack = $false
$p.NextText = 'Close'
$ui.LoginPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$ui.LoginPanel.FlowDirection = 'TopDown'; $ui.LoginPanel.AutoSize = $true; $ui.LoginPanel.WrapContents = $false
$ui.LoginPanel.Controls.Add((New-Label 'Sign in to Claude' -Bold))
$ui.LoginPanel.Controls.Add((New-Label ("A terminal window opens with Claude Code. Choose a theme, log in with your Claude account " +
  'and approve the sign-in in your browser. When Claude''s prompt appears, type /exit.')))
$ui.LoginButton = New-Button 'Sign in to Claude' 160
$ui.LoginPanel.Controls.Add($ui.LoginButton)
$ui.LoginStatus = New-Label '' -Bottom 14
$ui.LoginPanel.Controls.Add($ui.LoginStatus)
$p.Flow.Controls.Add($ui.LoginPanel)

$p.Flow.Controls.Add((New-Label 'Start working' -Bold))
$p.Flow.Controls.Add((New-Label ("Right-click a folder in Explorer and choose `"Open in claudejail`" " +
  '(on Windows 11 it is under "Show more options"), or start claudejail from the Start menu and pick a folder. ' +
  'Claude runs in a terminal window; closing it ends the session.')))
$p.Flow.Controls.Add((New-Label ("Tip: projects in the claudejail projects folder are much faster than projects on C:. " +
  'Folders on Windows drives work too.') -Color $colMuted -Bottom 10))
$row = New-Row
$ui.OpenProjects = New-Button 'Open projects folder' 170
$ui.OpenProject = New-Button 'Open a project...' 150
$row.Controls.Add($ui.OpenProjects)
$row.Controls.Add($ui.OpenProject)
$p.Flow.Controls.Add($row)
$p.Flow.Controls.Add((New-Label ("To update Claude Code or claudejail later, run `"claudejail setup (update or repair)`" from the Start menu. " +
  'Uninstall from the Start menu or Settings > Apps.') -Color $colMuted -Top 10))

function Test-SignedIn {
  $u = $state.Opt.User
  $r = Invoke-Native -FilePath $WslExe -NoLog -ArgumentList @('-d', $DistroName, '-u', $u, '--exec', 'test', '-s', "/home/$u/.claude/.credentials.json")
  return ($r.ExitCode -eq 0)
}
function Update-LoginStatus {
  if (Test-SignedIn) {
    $ui.LoginStatus.ForeColor = $colOk
    $ui.LoginStatus.Text = "$CHECK  Signed in"
    $ui.LoginButton.Text = 'Sign in again'
    $state.LoginPending = $false
  } else {
    $ui.LoginStatus.ForeColor = $colWarn
    $ui.LoginStatus.Text = 'Not signed in yet.'
  }
}

$p.OnEnter = {
  $ui.Cancel.Visible = $false
  $ui.LoginPanel.Visible = ($state.Opt.AuthMode -eq 'account')
  if ($ui.LoginPanel.Visible) { Update-LoginStatus }
}
$p.OnNext = {
  $state.CloseConfirmed = $true
  $form.Close()
  return $null
}

$launcherPath = Join-Path $AppDir 'Launch-ClaudeJail.ps1'
$ui.LoginButton.Add_Click({
  $state.LoginPending = $true
  Start-Process -FilePath $PowerShellExe -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcherPath + '" -Login')
  $ui.LoginStatus.ForeColor = $colMuted
  $ui.LoginStatus.Text = 'Waiting for you to sign in in the terminal window...'
})
$ui.OpenProject.Add_Click({
  Start-Process -FilePath $PowerShellExe -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcherPath + '"')
})
$ui.OpenProjects.Add_Click({
  Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('\\wsl$\' + $DistroName + '\home\' + $state.Opt.User + '\projects')
})
$form.Add_Activated({
  if ($state.Page -eq 'finish' -and $state.LoginPending) { Update-LoginStatus }
})

# ---------------------------------------------------------------------------
# Navigation, background-work polling, closing
# ---------------------------------------------------------------------------
$ui.Next.Add_Click({
  $page = $state.Pages[$state.Page]
  if (-not $page.OnNext) { return }
  $target = & $page.OnNext
  if ($target) { Show-Page $target }
})
$ui.Back.Add_Click({
  if ($state.History.Count -eq 0) { return }
  $prev = $state.History[$state.History.Count - 1]
  $state.History.RemoveAt($state.History.Count - 1)
  if ($prev -eq 'install') { $prev = 'options' }
  Show-Page $prev -NoHistory
})
$ui.Cancel.Add_Click({ $form.Close() })

$form.Add_FormClosing({
  param($sender, $e)
  if ($state.CloseConfirmed) { return }
  if ($state.Worker) {
    $answer = Show-Message 'Setup is still running. Stop it? You can run setup again later to finish.' 'Warning' 'YesNo'
    if ($answer -ne 'Yes') { $e.Cancel = $true; return }
    $sync.Cancel = $true
    try { if ($sync.CurrentProcess) { $sync.CurrentProcess.Kill() } } catch { }
  }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
  $sb = New-Object System.Text.StringBuilder
  $line = $null
  while ($sync.Log.TryDequeue([ref]$line)) { [void]$sb.AppendLine($line) }
  if ($sb.Length -gt 0) {
    $txt = $sb.ToString()
    try { [IO.File]::AppendAllText($LogPath, $txt) } catch { }
    if ($ui.Log.TextLength -gt 400000) { $ui.Log.Text = $ui.Log.Text.Substring(200000) }
    $ui.Log.AppendText($txt.Replace("`r`n", "`n").Replace("`n", "`r`n"))
  }
  if ($state.Page -eq 'install') {
    $t = $sync.StepText
    if ($sync.Detail) { $t = $t + ' - ' + $sync.Detail }
    if ($ui.Step.Text -ne $t) { $ui.Step.Text = $t }
    if ($sync.Percent -lt 0) {
      if ($ui.Progress.Style -ne 'Marquee') { $ui.Progress.Style = 'Marquee'; $ui.Progress.MarqueeAnimationSpeed = 30 }
    } else {
      if ($ui.Progress.Style -ne 'Continuous') { $ui.Progress.Style = 'Continuous' }
      $ui.Progress.Value = [Math]::Min(100, [Math]::Max(0, [int]$sync.Percent))
    }
  }
  $w = $state.Worker
  if ($w -and $w.Handle.IsCompleted) {
    $state.Worker = $null
    try { [void]$w.PS.EndInvoke($w.Handle) } catch { if (-not $sync.Error) { $sync.Error = $_.Exception.Message } }
    $w.PS.Dispose()
    $w.RS.Dispose()
    & $w.OnDone
  }
})

$form.Add_Shown({
  New-Item -ItemType Directory -Force -Path $AppRoot | Out-Null
  $timer.Start()
  Show-Page 'welcome'
})

[void]$form.ShowDialog()
$timer.Stop()
