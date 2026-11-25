<#
  Opens a folder in claudejail.

  Used by the Start menu shortcut (no argument: shows a folder picker) and by
  the "Open in claudejail" entry in Explorer's folder right-click menu
  (folder path as argument). -Login opens the Claude sign-in instead.

  Windows PowerShell 5.1 compatible. Keep this file ASCII-only.
#>
param(
  [string]$Path,
  [switch]$Login
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

function Show-Error([string]$Message) {
  [void][System.Windows.Forms.MessageBox]::Show($Message, 'claudejail',
    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
  exit 1
}

# Quote arguments for a Windows command line (CommandLineToArgvW rules).
function Join-Args([string[]]$ArgumentList) {
  $parts = foreach ($a in $ArgumentList) {
    if ($null -eq $a -or $a -eq '') { '""' }
    elseif ($a -notmatch '[\s"]') { $a }
    else { '"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
  }
  $parts -join ' '
}

$configPath = Join-Path $PSScriptRoot 'config.json'
try {
  $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
} catch {
  Show-Error 'claudejail is not set up yet. Run the claudejail setup first.'
}

function ConvertTo-LinuxPath([string]$WinPath) {
  # \\wsl$\claudejail\home\me\projects or \\wsl.localhost\claudejail\...
  if ($WinPath -match '^\\\\(?:wsl\$|wsl\.localhost)\\([^\\]+)(\\.*)?$') {
    $distro = $Matches[1]
    $rest = $Matches[2]
    if ($distro -ne $cfg.Distro) {
      Show-Error ("That folder is inside another WSL distribution ($distro). " +
        'Put the project in the claudejail projects folder or on a Windows drive.')
    }
    if (-not $rest) { return '/' }
    $p = ($rest -replace '\\', '/').TrimEnd('/')
    if (-not $p) { return '/' }
    return $p
  }
  # C:\Users\me\code -> /mnt/c/Users/me/code
  if ($WinPath -match '^([A-Za-z]):\\?(.*)$') {
    $p = '/mnt/' + $Matches[1].ToLowerInvariant()
    $rest = ($Matches[2] -replace '\\', '/').TrimEnd('/')
    if ($rest) { $p += '/' + $rest }
    return $p
  }
  Show-Error 'Network folders are not supported. Copy the project to a local drive or into the claudejail projects folder.'
}

$linuxHome = '/home/' + $cfg.User

if ($Login) {
  $command = @('/usr/local/bin/claudejail-login')
  $title = 'Sign in to Claude'
} else {
  if (-not $Path) {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose the project folder to open in claudejail'
    $dialog.ShowNewFolderButton = $true
    $dialog.SelectedPath = '\\wsl$\' + $cfg.Distro + ($linuxHome -replace '/', '\') + '\projects'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { exit 0 }
    $Path = $dialog.SelectedPath
  }
  # Explorer passes "C:\" as C:" because of the trailing backslash before the quote.
  $Path = $Path.Trim().Trim('"')
  if ($Path -match '^[A-Za-z]:$') { $Path += '\' }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Show-Error "Folder not found: $Path"
  }
  $command = @('/usr/local/bin/claudejail-session')
  if ($cfg.SshKey) {
    $command += @('--ssh-key', "$linuxHome/.ssh/$($cfg.SshKey)")
  }
  $command += (ConvertTo-LinuxPath $Path)
  $leaf = Split-Path -Path $Path -Leaf
  if (-not $leaf) { $leaf = $Path }
  $title = "claudejail - $leaf"
}

$wslArgs = @('-d', $cfg.Distro, '-u', $cfg.User, '--cd', '~', '--exec') + $command
$wslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'

$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($wt) {
  # Windows Terminal treats ";" as a command separator; escape it.
  $all = @('-w', 'new', '--title', $title, '--suppressApplicationTitle', 'wsl.exe') + $wslArgs
  Start-Process -FilePath $wt.Source -ArgumentList ((Join-Args $all) -replace ';', '\;')
} else {
  Start-Process -FilePath $wslExe -ArgumentList (Join-Args $wslArgs)
}
