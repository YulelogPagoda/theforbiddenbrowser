# 🏖️ The Forbidden Browser

![The Forbidden Browser](https://github.com/YulelogPagoda/theforbiddenbrowser/raw/main/Designer.png)

# The Forbidden Browser — Understanding WebView2, CVEs, and Evergreen Updates

> **TL;DR**  
> - **WebView2** lets native Windows apps embed web content using the **Chromium** engine.  
> - Because it uses the same engine, **many Edge/Chrome CVEs also impact WebView2**.  
> - **Evergreen** keeps the WebView2 Runtime auto‑patched. Turning it off (or blocking browser updates) can **strand** the runtime on **vulnerable** builds.

---

## This has been submitted to MSRC as vulnerability that they identified as a product issue and the Edge team has said that they'll be putting CVEs from Edge as CVEs for EdgeWebview2 in the future.

**First things first:**  
This repo includes **`Snarf.ps1`**, a PowerShell script that demonstrates how to run **Edge WebView2 as its own browser instance**. It fetches a target URL and renders it using the WebView2 runtime, proving that WebView2 isn’t just a control—it can behave like a standalone browser when invoked programmatically.

Example:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\snarf.ps1 -Url "https://www.slashdot.org" -Title "DR"
```


## 1) What is WebView2?

**Microsoft Edge WebView2** is a control developers embed inside Win32/.NET/WinUI apps to render HTML/JS/CSS with the **Microsoft Edge (Chromium)** engine. It offers two distribution models:

- **Evergreen Runtime** – a shared, auto‑updating runtime that tracks Stable Chromium/Edge (recommended).  
- **Fixed Version Runtime** – a specific, app‑packaged version that doesn’t auto‑update (used when strict version pinning is required).

Key points:

- On Windows 11, the **Evergreen Runtime is preinstalled** and serviced automatically when connectivity is available.  
- In **production**, WebView2 apps are **not allowed** to use the Edge Stable browser binaries directly; they must use the **WebView2 Runtime**. This avoids coupling app security/availability to browser servicing policy.

---

To see what versions of EdgeWebView2 you're running right now:
```powershell
Get-CimInstance Win32_Process -Filter "Name like 'msedgewebview2.exe'" | Select-Object ProcessId, ParentProcessId, CommandLine
```

## 2) Why Edge/Chrome CVEs usually affect WebView2

WebView2’s runtime is **Chromium‑based**. Vulnerabilities in engines like **Blink**/**V8** (e.g., type confusion, JIT bugs, sandbox escapes) typically affect **Chrome**, **Edge**, and **WebView2** because they share core code. When Microsoft releases Edge Stable with security fixes, the **WebView2 Evergreen Runtime** receives the same underlying engine updates. Blocking or delaying those updates keeps apps running **older, exploitable** engines.

> Example: A **V8 type confusion RCE** patched in Chrome/Edge will also need the **WebView2 Runtime** updated to remove the risk from embedded app surfaces.

---

## 3) Evergreen vs. Fixed Version — What enterprises need to know

### Evergreen (recommended)
- **Auto‑updates** the runtime on client machines.  
- **Shared** by all WebView2 apps → reduced disk/memory footprint (hard‑links with Edge when versions match).  
- Best security posture; minimal operational overhead.

### Fixed Version (pinning)
- **No automatic updates**. You ship and service a specific runtime version with your app.  
- Useful for regulated environments with strict compatibility testing, but you **inherit patching responsibility**.

> **Caution:** Some organisations try to block Edge/Chrome auto‑updates via GPO/registry and assume WebView2 follows suit. In fact, **production WebView2 apps depend on the WebView2 Runtime**, which should be serviced independently; blocking browser updates **does not eliminate** the requirement to keep the **runtime** secure.

---

## 4) Common enterprise pitfalls (and how to avoid them)

1. **Disabling Evergreen updates “for compatibility”**  
   - *Risk:* Leaves the **runtime** stuck on vulnerable builds even if the browser is controlled.  
   - *Fix:* If you must control the browser, **do not block WebView2 Runtime servicing**. For regulated cases, use **Fixed Version** and create a rapid patch cadence for the packaged runtime.

2. **Assuming the app uses Edge Stable as its engine**  
   - *Reality:* Production apps **must use** the WebView2 Runtime; Edge Stable isn’t supported as the backing platform.

3. **No inventory of apps that ship WebView2**  
   - *Impact:* You can’t validate exposure when a Chromium CVE drops. Maintain a catalogue of **processes using `msedgewebview2.exe`** and correlate versions.

4. **Testing only the browser**  
   - *Action:* Test **WebView2 Runtime** builds against your app UAT, not just Edge Stable. Use Insider channels for forward‑compat checks where needed.

---

## 5) SecOps playbook: visibility, detection, and patching

- **Asset & version inventory**  
  - Enumerate installed **WebView2 Runtime** versions across endpoints (look for `C:\Program Files (x86)\Microsoft\EdgeWebView\Application\<version>\msedgewebview2.exe`).  
  - Alert on versions **older** than the current Stable runtime.

- **Process telemetry**  
  - Watch for suspicious children of `msedgewebview2.exe`/`msedge.exe` (e.g., `powershell.exe`, `cmd.exe`, `mshta.exe`, `rundll32.exe`) with network egress or encoded payloads after browser/WebView exploitation attempts.

- **Patching**  
  - **Evergreen**: verify devices can reach Microsoft update endpoints or WSUS/ConfigMgr packages for the WebView2 Runtime.  
  - **Fixed Version**: integrate runtime updates into your **normal app patch train**; treat engine updates like critical library updates.

---

## 6) Governance & policy recommendations

- **Default to Evergreen** for line‑of‑business apps unless you have a validated need to pin.  
- If browser updates are centrally controlled, **explicitly exempt WebView2 Runtime servicing** paths so the engine isn’t stranded.  
- Maintain a **CVE mapping** between Chromium/Edge advisories and internal WebView2‑based apps.  
- Include WebView2 Runtime checks in **build gates** and **security baselines**.

---

## 7) Running `Snarf.ps1` (demo utility)

This repository includes a simple PowerShell helper, **`Snarf.ps1`**, that retrieves a target URL’s content and stores the result with a custom title—handy for demos, triage, or quick reproducibility checks when investigating WebView2/Chromium rendering behaviours.

> **Usage example**  
> Run PowerShell **as a standard user** in the repo folder:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\snarf.ps1 -Url "https://www.slashdot.org" -Title "DR"
