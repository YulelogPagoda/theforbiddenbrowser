#requires -Version 5.1
param(
  [string]$Url         = 'https://www.dr.dk',
  [string]$Title       = 'WebView2 Host',
  [int]   $Width       = 1100,
  [int]   $Height      = 800,
  # Optional persistent profile (cookies/cache); set '' to use an ephemeral session
  [string]$UserDataDir = "$env:USERPROFILE\Documents\WebView2Host\UserData"
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# --- Paths (all user-writable) ---
$BaseDir   = Join-Path $env:USERPROFILE 'Documents\WebView2Host'
$PkgsDir   = Join-Path $BaseDir 'Packages'
$Extracted = Join-Path $BaseDir 'Extracted'
$Runtime   = Join-Path $BaseDir 'Runtime'
$null = New-Item -ItemType Directory -Path $BaseDir,$PkgsDir,$Extracted,$Runtime -Force -ErrorAction SilentlyContinue

# --- Helper: choose best TFM for current host ---
function Get-BestTfm {
  param([string]$LibRoot)
  $isDesktop = ($PSVersionTable.PSEdition -eq 'Desktop') # Windows PowerShell 5.1
  $desktopTFMs = @('net48','net472','net471','net462')
  $coreTFMs    = @('net8.0-windows','net7.0-windows','net6.0-windows','net5.0-windows')

  $order = if ($isDesktop) { $desktopTFMs } else { $coreTFMs + $desktopTFMs }
  foreach ($tfm in $order) {
    $path = Join-Path $LibRoot $tfm
    if (Test-Path (Join-Path $path 'Microsoft.Web.WebView2.Core.dll') -and
        (Test-Path (Join-Path $path 'Microsoft.Web.WebView2.WinForms.dll'))) {
      return $path
    }
  }
  return $null
}

# --- Helper: download a specific version; return extracted info or $null if unsuitable ---
function Use-WebView2Version {
  param([string]$Version)

  $idLower = 'microsoft.web.webview2'
  $nupkgName = "$idLower.$Version.nupkg"
  $nupkgPath = Join-Path $PkgsDir $nupkgName
  $nupkgUrl  = "https://api.nuget.org/v3-flatcontainer/$idLower/$Version/$nupkgName"

  if (-not (Test-Path $nupkgPath)) {
    Write-Host "Downloading Microsoft.Web.WebView2 $Version ..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $nupkgUrl -OutFile $nupkgPath
  } else {
    Write-Host "Using cached package $nupkgName" -ForegroundColor DarkCyan
  }

  $verExtract = Join-Path $Extracted $Version
  if (-not (Test-Path $verExtract)) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($nupkgPath, $verExtract)
  }

  $libRoot = Join-Path $verExtract 'lib'
  $tfmPath = Get-BestTfm -LibRoot $libRoot
  if (-not $tfmPath) {
    Write-Host "Version $Version does not contain managed WinForms assemblies (skipping)..." -ForegroundColor DarkYellow
    return $null
  }

  # Pick native loader matching current process bitness
  $arch = if ([Environment]::Is64BitProcess) { 'win-x64' } else { 'win-x86' }
  $loader = Join-Path $verExtract ("runtimes\$arch\native\WebView2Loader.dll")
  if (-not (Test-Path $loader)) {
    Write-Host "Version $Version missing native WebView2Loader.dll for $arch (skipping)..." -ForegroundColor DarkYellow
    return $null
  }

  # Copy the three redistributables into Runtime
  Copy-Item (Join-Path $tfmPath 'Microsoft.Web.WebView2.Core.dll')    $Runtime -Force
  Copy-Item (Join-Path $tfmPath 'Microsoft.Web.WebView2.WinForms.dll') $Runtime -Force
  Copy-Item $loader $Runtime -Force

  [PSCustomObject]@{
    Version     = $Version
    CorePath    = Join-Path $Runtime 'Microsoft.Web.WebView2.Core.dll'
    WinFormsDll = Join-Path $Runtime 'Microsoft.Web.WebView2.WinForms.dll'
    LoaderPath  = Join-Path $Runtime 'WebView2Loader.dll'
  }
}

# --- Find latest usable version (with managed DLLs) ---
Write-Host "Querying NuGet for available versions..." -ForegroundColor Cyan
$versions = (Invoke-RestMethod "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/index.json").versions
# Sort descending as System.Version; filter out pre-release if any appear
$sorted = $versions | ForEach-Object { $_ } | Sort-Object {[version]$_} -Descending

$selected = $null
foreach ($v in $sorted) {
  $selected = Use-WebView2Version -Version $v
  if ($selected) { break }
}
if (-not $selected) {
  throw "Could not find any Microsoft.Web.WebView2 version with managed WinForms assemblies and a matching native loader."
}

Write-Host "Using Microsoft.Web.WebView2 $($selected.Version)" -ForegroundColor Green

# --- Prep load paths ---
# Make sure native loader is discoverable
if ($env:Path.Split(';') -notcontains $Runtime) { $env:Path = "$Runtime;$env:Path" }

# Load managed assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path $selected.CorePath, $selected.WinFormsDll

# --- Tiny C# host compiled in-memory ---
$code = @"
using System;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

public static class MiniWV2
{
    [STAThread]
    public static void Run(string url, int width, int height, string title, string userDataDir)
    {
        Application.EnableVisualStyles();
        var form = new Form() {
            Text = title,
            Width = width,
            Height = height,
            StartPosition = FormStartPosition.CenterScreen
        };

        var wv = new WebView2() { Dock = DockStyle.Fill };
        form.Controls.Add(wv);

        form.Shown += async (s, e) =>
        {
            CoreWebView2Environment env;
            if (!string.IsNullOrWhiteSpace(userDataDir))
                env = await CoreWebView2Environment.CreateAsync(null, userDataDir);
            else
                env = await CoreWebView2Environment.CreateAsync();

            await wv.EnsureCoreWebView2Async(env);

            // Optional hardening/UX tweaks (uncomment if needed)
            // wv.CoreWebView2.Settings.AreDevToolsEnabled = false;
            // wv.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
            // wv.CoreWebView2.Settings.IsStatusBarEnabled = false;

            wv.CoreWebView2.Navigate(url);
        };

        Application.Run(form);
    }
}
"@

Add-Type -ReferencedAssemblies @('System.Windows.Forms.dll', $selected.CorePath, $selected.WinFormsDll) `
         -TypeDefinition $code -Language CSharp

# --- Launch ---
[MiniWV2]::Run($Url, $Width, $Height, $Title, $UserDataDir)
