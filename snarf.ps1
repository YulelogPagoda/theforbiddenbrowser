#requires -Version 5.1
param(
  [string]$Url               = 'https://www.dr.dk',
  [string]$Title             = 'WebView2 Browser',
  [int]   $Width             = 1100,
  [int]   $Height            = 800,
  [string]$UserDataDir       = "$env:USERPROFILE\Documents\WebView2Host\UserData",

  # Optional hardening flags (safe defaults)
  [switch]$DisableDevTools,                # default: enabled; pass to disable
  [switch]$DisableContextMenu,             # default: enabled; pass to disable
  [switch]$BlockNonHttp,                   # cancels navigation to non-http/https schemes
  [switch]$DenyAllPermissions,             # deny camera/mic/geo/clipboard/etc. prompts

  # Optional: choose WebView2 package version ('latest' or a specific version)
  [string]$WebView2Version = 'latest',

  # Tab strip behavior
  [int]$TabWidth = 140,                    # width per tab header (px)
  [bool]$TabsMultiline = $true             # wrap tabs onto multiple rows by default
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# --- Paths ---
$BaseDir   = Join-Path $env:USERPROFILE 'Documents\WebView2Host'
$PkgsDir   = Join-Path $BaseDir 'Packages'
$Extracted = Join-Path $BaseDir 'Extracted'
$Runtime   = Join-Path $BaseDir 'Runtime'
$null = New-Item -ItemType Directory -Path $BaseDir,$PkgsDir,$Extracted,$Runtime -Force -ErrorAction SilentlyContinue

function Get-BestTfm {
  param([string]$LibRoot)
  $isDesktop   = ($PSVersionTable.PSEdition -eq 'Desktop')
  $desktopTFMs = @('net481','net48','net472','net471','net462')
  $coreTFMs    = @('net8.0-windows','net7.0-windows','net6.0-windows','net5.0-windows')
  $order = if ($isDesktop) { $desktopTFMs } else { $coreTFMs + $desktopTFMs }
  foreach ($tfm in $order) {
    $path = Join-Path $LibRoot $tfm
    if (
      (Test-Path (Join-Path $path 'Microsoft.Web.WebView2.Core.dll')) -and
      (Test-Path (Join-Path $path 'Microsoft.Web.WebView2.WinForms.dll'))
    ) { return $path }
  }
  return $null
}

function Get-WebView2Arch {
  # Choose the loader architecture appropriate for THIS process
  $procArch = $env:PROCESSOR_ARCHITECTURE
  if ($procArch -match 'ARM64') {
    if ([Environment]::Is64BitProcess) { return 'win-arm64' } else { return 'win-x86' }
  } else {
    if ([Environment]::Is64BitProcess) { return 'win-x64' } else { return 'win-x86' }
  }
}

function Use-WebView2Version {
  param([string]$Version)

  $idLower = 'microsoft.web.webview2'
  if ($Version -eq 'latest') {
    Write-Host "Querying NuGet for available versions..." -ForegroundColor Cyan
    $all = (Invoke-RestMethod "https://api.nuget.org/v3-flatcontainer/$idLower/index.json").versions
    $stable = $all | Where-Object { $_ -notmatch '-' }
    $sorted = $stable | Sort-Object { [version]$_ } -Descending
    $Version = $sorted[0]
  }

  $nupkgName = "$idLower.$Version.nupkg"
  $nupkgPath = Join-Path $PkgsDir $nupkgName
  $nupkgUrl  = "https://api.nuget.org/v3-flatcontainer/$idLower/$Version/$nupkgName"

  if (-not (Test-Path $nupkgPath)) {
    Write-Host "Downloading $idLower $Version ..." -ForegroundColor Cyan
    try {
      Invoke-WebRequest -Uri $nupkgUrl -OutFile $nupkgPath -UseBasicParsing
    } catch {
      throw "Failed to download $nupkgUrl. Check connectivity/proxy and try again or pin -WebView2Version to a cached one."
    }
  }

  $verExtract = Join-Path $Extracted $Version
  if (-not (Test-Path $verExtract)) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($nupkgPath, $verExtract)
  }

  $libRoot = Join-Path $verExtract 'lib'
  $tfmPath = Get-BestTfm -LibRoot $libRoot
  if (-not $tfmPath) { return $null }

  $arch = Get-WebView2Arch
  $loader = Join-Path $verExtract ("runtimes\$arch\native\WebView2Loader.dll")
  if (-not (Test-Path $loader)) {
    if ($arch -eq 'win-arm64' -and [Environment]::Is64BitProcess) {
      $loader = Join-Path $verExtract ("runtimes\win-x64\native\WebView2Loader.dll")
    }
  }
  if (-not (Test-Path $loader)) { return $null }

  Copy-Item (Join-Path $tfmPath 'Microsoft.Web.WebView2.Core.dll')     $Runtime -Force
  Copy-Item (Join-Path $tfmPath 'Microsoft.Web.WebView2.WinForms.dll') $Runtime -Force
  Copy-Item $loader $Runtime -Force

  [PSCustomObject]@{
    Version     = $Version
    CorePath    = Join-Path $Runtime 'Microsoft.Web.WebView2.Core.dll'
    WinFormsDll = Join-Path $Runtime 'Microsoft.Web.WebView2.WinForms.dll'
    LoaderPath  = Join-Path $Runtime 'WebView2Loader.dll'
  }
}

$selected = Use-WebView2Version -Version $WebView2Version
if (-not $selected) { throw "No usable WebView2 version found." }

Write-Host "Using Microsoft.Web.WebView2 $($selected.Version)" -ForegroundColor Green
if ($env:Path.Split(';') -notcontains $Runtime) { $env:Path = "$Runtime;$env:Path" }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path $selected.CorePath, $selected.WinFormsDll

# --- C# 5-compatible code with tabs, multiline, and tab list (no duplicate variables) ---
$code = @'
using System;
using System.Drawing;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

public static class MiniWV2
{
    [STAThread]
    public static void Run(string url, int width, int height, string title, string userDataDir,
                           bool disableDevTools, bool disableContextMenu, bool blockNonHttp, bool denyAllPermissions,
                           int tabWidth, bool tabsMultiline)
    {
        Application.EnableVisualStyles();

        var form = new Form() {
            Text = title,
            Width = width,
            Height = height,
            StartPosition = FormStartPosition.CenterScreen
        };

        // Toolbar: Back | Forward | Refresh | [Address] | Go | + | ✖ | ▼
        var toolbar = new TableLayoutPanel() { Dock = DockStyle.Top, Height = 32, ColumnCount = 8 };
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 30));
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 30));
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 30));
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 40));
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 32));
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 32));
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 36));

        var backBtn  = new Button() { Text = "<", Dock = DockStyle.Fill, TabStop = false };
        var fwdBtn   = new Button() { Text = ">", Dock = DockStyle.Fill, TabStop = false };
        var refBtn   = new Button() { Text = "↻", Dock = DockStyle.Fill, TabStop = false };
        var addrBox  = new TextBox() { Text = url, Dock = DockStyle.Fill };
        var goBtn    = new Button() { Text = "Go", Dock = DockStyle.Fill, TabStop = false };
        var newBtn   = new Button() { Text = "+", Dock = DockStyle.Fill, TabStop = false };
        var closeBtn = new Button() { Text = "✖", Dock = DockStyle.Fill, TabStop = false };
        var listBtn  = new Button() { Text = "▼", Dock = DockStyle.Fill, TabStop = false };

        toolbar.Controls.Add(backBtn,  0, 0);
        toolbar.Controls.Add(fwdBtn,   1, 0);
        toolbar.Controls.Add(refBtn,   2, 0);
        toolbar.Controls.Add(addrBox,  3, 0);
        toolbar.Controls.Add(goBtn,    4, 0);
        toolbar.Controls.Add(newBtn,   5, 0);
        toolbar.Controls.Add(closeBtn, 6, 0);
        toolbar.Controls.Add(listBtn,  7, 0);

        var tabs = new TabControl() { Dock = DockStyle.Fill };
        tabs.ShowToolTips = true;
        if (tabsMultiline)
        {
            tabs.Multiline = true;
            tabs.SizeMode  = TabSizeMode.Fixed;
            tabs.ItemSize  = new Size(tabWidth, 22);
            tabs.Padding   = new Point(8, 3);
        }

        // Right-click tab context menu (define once)
        var tabMenu = new ContextMenuStrip();
        var miClose       = new ToolStripMenuItem("Close Tab");
        var miCloseOthers = new ToolStripMenuItem("Close Other Tabs");
        var miDuplicate   = new ToolStripMenuItem("Duplicate Tab");
        tabMenu.Items.AddRange(new ToolStripItem[] { miClose, miCloseOthers, miDuplicate });

        // Show context menu on tab under cursor
        tabs.MouseUp += (s, e) =>
        {
            if (e.Button != MouseButtons.Right) return;
            for (int i = 0; i < tabs.TabPages.Count; i++)
            {
                if (tabs.GetTabRect(i).Contains(e.Location))
                {
                    tabs.SelectedIndex = i;
                    tabMenu.Show(tabs, e.Location);
                    break;
                }
            }
        };

        // "All tabs" dropdown
        var allTabsMenu = new ContextMenuStrip();
        listBtn.Click += (s, e) =>
        {
            allTabsMenu.Items.Clear();
            for (int i = 0; i < tabs.TabPages.Count; i++)
            {
                var tp = tabs.TabPages[i];
                var item = new ToolStripMenuItem(tp.Text);
                int idx = i;
                item.ToolTipText = tp.ToolTipText;
                item.Click += (ss, ee) => { tabs.SelectedIndex = idx; };
                allTabsMenu.Items.Add(item);
            }
            var pt = listBtn.PointToScreen(new Point(0, listBtn.Height));
            allTabsMenu.Show(pt);
        };

        form.Controls.Add(tabs);
        form.Controls.Add(toolbar);
        form.Controls.SetChildIndex(toolbar, 0);

        form.KeyPreview = true;

        CoreWebView2Environment env = null;

        // Helpers
        Func<WebView2> getActiveWV = () =>
        {
            var tp = tabs.SelectedTab;
            if (tp == null) return null;
            return tp.Tag as WebView2;
        };

        Func<string,int,string> shorten = (s, max) =>
        {
            try {
                if (String.IsNullOrEmpty(s)) return "New Tab";
                if (s.Length <= max) return s;
                return s.Substring(0, Math.Max(0, max - 1)) + "…";
            } catch { return s; }
        };

        Action updateUI = () =>
        {
            try {
                var wv = getActiveWV();
                bool ready = (wv != null && wv.CoreWebView2 != null);
                backBtn.Enabled  = ready && wv.CoreWebView2.CanGoBack;
                fwdBtn.Enabled   = ready && wv.CoreWebView2.CanGoForward;
                refBtn.Enabled   = ready;
                goBtn.Enabled    = true;
                closeBtn.Enabled = tabs.TabPages.Count > 0;

                if (ready)
                {
                    try { addrBox.Text = wv.CoreWebView2.Source; } catch {}
                }
            } catch {}
        };

        Func<string, string> normalizeAddress = (input) =>
        {
            try {
                if (string.IsNullOrWhiteSpace(input)) return input;
                string t = input.Trim();
                Uri u;
                if (Uri.TryCreate(t, UriKind.Absolute, out u)) return t;
                if (!t.Contains("://") && !t.StartsWith("about:", StringComparison.OrdinalIgnoreCase))
                    return "https://" + t;
                return t;
            } catch { return input; }
        };

        Func<string, Task> addTab = null;
        addTab = async (initialUrl) =>
        {
            try
            {
                var tp = new TabPage("New Tab");
                var wv = new WebView2() { Dock = DockStyle.Fill };
                tp.Tag = wv;
                tp.Controls.Add(wv);
                tabs.TabPages.Add(tp);
                tabs.SelectedTab = tp;

                if (env == null)
                {
                    if (!string.IsNullOrWhiteSpace(userDataDir))
                        env = await CoreWebView2Environment.CreateAsync(null, userDataDir);
                    else
                        env = await CoreWebView2Environment.CreateAsync();
                }

                await wv.EnsureCoreWebView2Async(env);

                // Safer defaults per tab
                var settings = wv.CoreWebView2.Settings;
                settings.AreDefaultContextMenusEnabled = !disableContextMenu;
                settings.AreDevToolsEnabled            = !disableDevTools;
                settings.IsPasswordAutosaveEnabled     = false;
                settings.IsGeneralAutofillEnabled      = false;
                settings.IsStatusBarEnabled            = true;
                settings.IsZoomControlEnabled          = true;

                if (denyAllPermissions)
                {
                    wv.CoreWebView2.PermissionRequested += (sender, args) =>
                    {
                        args.State = CoreWebView2PermissionState.Deny;
                    };
                }

                if (blockNonHttp)
                {
                    wv.CoreWebView2.NavigationStarting += (sender, args) =>
                    {
                        try {
                            var u = new Uri(args.Uri);
                            if (!u.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase) &&
                                !u.Scheme.Equals("http",  StringComparison.OrdinalIgnoreCase))
                            {
                                args.Cancel = true;
                            }
                        } catch { args.Cancel = true; }
                    };
                }

                // Update tab title from document title
                wv.CoreWebView2.DocumentTitleChanged += (sender, args) =>
                {
                    try {
                        string full = wv.CoreWebView2.DocumentTitle;
                        if (string.IsNullOrEmpty(full)) full = "New Tab";
                        tp.Text = shorten(full, Math.Max(40, tabWidth / 4));
                        tp.ToolTipText = full;
                    } catch {}
                };

                // Keep UI in sync
                wv.CoreWebView2.HistoryChanged += (sender, args) => { updateUI(); };
                wv.CoreWebView2.NavigationCompleted += (sender, args) =>
                {
                    try { addrBox.Text = wv.CoreWebView2.Source; } catch {}
                    updateUI();
                };

                // target=_blank -> open in new tab
                wv.CoreWebView2.NewWindowRequested += (sender, ne) =>
                {
                    ne.Handled = true;
                    try {
                        if (!string.IsNullOrWhiteSpace(ne.Uri))
                            addTab(ne.Uri).ContinueWith(t => { });
                    } catch {}
                };

                // Navigate
                string nav = initialUrl;
                if (!string.IsNullOrWhiteSpace(nav)) nav = normalizeAddress(nav);
                if (!string.IsNullOrWhiteSpace(nav))
                    wv.CoreWebView2.Navigate(nav);

                updateUI();
            }
            catch (Exception ex)
            {
                MessageBox.Show("Failed to create tab.\n\n" + ex.Message, "WebView2 Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        };

        // Toolbar actions
        Action goNavigate = () =>
        {
            try {
                var wv = getActiveWV();
                if (wv == null || wv.CoreWebView2 == null) return;
                string nav = normalizeAddress(addrBox.Text);
                if (!string.IsNullOrWhiteSpace(nav))
                    wv.CoreWebView2.Navigate(nav);
            } catch {}
        };

        backBtn.Click += (sender, args) => { try { var wv = getActiveWV(); if (wv != null && wv.CoreWebView2 != null && wv.CoreWebView2.CanGoBack) wv.CoreWebView2.GoBack(); } catch {} };
        fwdBtn.Click  += (sender, args) => { try { var wv = getActiveWV(); if (wv != null && wv.CoreWebView2 != null && wv.CoreWebView2.CanGoForward) wv.CoreWebView2.GoForward(); } catch {} };
        refBtn.Click  += (sender, args) => { try { var wv = getActiveWV(); if (wv != null && wv.CoreWebView2 != null) wv.CoreWebView2.Reload(); } catch {} };
        goBtn.Click   += (sender, args) => { goNavigate(); };
        newBtn.Click  += (sender, args) => { addTab(url).ContinueWith(t => { }); };
        closeBtn.Click+= (sender, args) =>
        {
            try {
                if (tabs.TabPages.Count > 1)
                {
                    var tp = tabs.SelectedTab;
                    var wv = getActiveWV();
                    tabs.TabPages.Remove(tp);
                    try { if (wv != null) wv.Dispose(); } catch {}
                    updateUI();
                }
                else
                {
                    form.Close();
                }
            } catch {}
        };

        // Context menu actions
        miClose.Click += (s, e) => { closeBtn.PerformClick(); };
        miCloseOthers.Click += (s, e) =>
        {
            try {
                var keep = tabs.SelectedTab;
                for (int i = tabs.TabPages.Count - 1; i >= 0; i--)
                {
                    var tp = tabs.TabPages[i];
                    if (!Object.ReferenceEquals(tp, keep))
                    {
                        var wv = tp.Tag as WebView2;
                        tabs.TabPages.RemoveAt(i);
                        try { if (wv != null) wv.Dispose(); } catch {}
                    }
                }
                updateUI();
            } catch {}
        };
        miDuplicate.Click += (s, e) =>
        {
            try {
                var wv = getActiveWV();
                if (wv != null && wv.CoreWebView2 != null)
                    addTab(wv.CoreWebView2.Source).ContinueWith(t => { });
            } catch {}
        };

        addrBox.KeyDown += (sender, args) =>
        {
            if (args.KeyCode == Keys.Enter)
            {
                goNavigate();
                args.SuppressKeyPress = true;
            }
        };

        tabs.SelectedIndexChanged += (sender, args) => { updateUI(); };

        // Shortcuts
        form.KeyDown += (sender, args) =>
        {
            try {
                var wv = getActiveWV();
                if (args.KeyCode == Keys.F5) { if (wv != null && wv.CoreWebView2 != null) wv.CoreWebView2.Reload(); }
                else if (args.Alt && args.KeyCode == Keys.Left)  { if (wv != null && wv.CoreWebView2 != null && wv.CoreWebView2.CanGoBack)    wv.CoreWebView2.GoBack(); }
                else if (args.Alt && args.KeyCode == Keys.Right) { if (wv != null && wv.CoreWebView2 != null && wv.CoreWebView2.CanGoForward) wv.CoreWebView2.GoForward(); }
                else if (args.Control && args.KeyCode == Keys.L) { addrBox.Focus(); addrBox.SelectAll(); }
                else if (args.Control && args.KeyCode == Keys.T) { addTab(url).ContinueWith(t => { }); }
                else if (args.Control && args.KeyCode == Keys.W) { closeBtn.PerformClick(); }
            } catch {}
        };

        // Initialize first tab
        form.Shown += async (s, e) =>
        {
            try { await addTab(url); }
            catch (Exception ex)
            {
                MessageBox.Show("Failed to initialize WebView2.\n\n" + ex.Message +
                                "\n\nIf the Evergreen Runtime is not installed, please install it and try again.",
                                "WebView2 Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                form.Close();
            }
        };

        form.FormClosed += (s, e) =>
        {
            try {
                foreach (TabPage tp in tabs.TabPages)
                {
                    var wv = tp.Tag as WebView2;
                    if (wv != null) { try { wv.Dispose(); } catch {} }
                }
            } catch {}
        };

        Application.Run(form);
    }
}
'@

# Compile the host type (C#)
Add-Type -ReferencedAssemblies @('System.Windows.Forms','System.Drawing', $selected.CorePath, $selected.WinFormsDll) `
         -TypeDefinition $code -Language CSharp

# Run the host
[MiniWV2]::Run(
  $Url, $Width, $Height, $Title, $UserDataDir,
  [bool]$DisableDevTools, [bool]$DisableContextMenu, [bool]$BlockNonHttp, [bool]$DenyAllPermissions,
  [int]$TabWidth, [bool]$TabsMultiline
)
