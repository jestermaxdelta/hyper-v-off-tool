# Hyper-V Off Tool

A premium dark-themed Windows utility that **fully disables Hyper-V, VBS (Virtualization Based Security), Credential Guard, Memory Integrity (HVCI), Windows Hello PIN sign-in, and every Windows feature that depends on the Microsoft hypervisor** — with built-in safety rails, automatic restart handling, and a clean customer-facing UI.

Built for Windows PowerShell 5.1 (built into Windows). No dependencies, no install.

### ⬇ [Download the latest version](https://github.com/jestermaxdelta/hyper-v-off-tool/releases/latest)

Grab the `HyperV-Off-Tool-vX.Y.Z.zip` file under **Assets**, extract it (right-click → **Extract All**), and double-click `Start-HyperV-Off-Console.cmd`.

---

## Features

### Core disablement
- **Full hypervisor shutdown** — sets `hypervisorlaunchtype off` and `vsmlaunchtype off` in the boot configuration (BCD).
- **Windows features removed** — Hyper-V, Virtual Machine Platform, Hypervisor Platform, Windows Sandbox, Application Guard, Isolated User Mode, and WSL 2's hypervisor dependency.
- **VBS / Credential Guard / HVCI / System Guard / Kernel Shadow Stacks** — explicit off values written to both policy and configuration registry locations.
- **UEFI firmware lock removal** — stages Microsoft's own `SecConfig.efi` opt-out flow (the same one the DG Readiness tool uses) so firmware-locked VBS policies can be cleared. Requires pressing the key shown on screen at boot (commonly **F3**).
- **Windows Server is detected up front** — Server has no System Restore, so the window explains this and blocks the run before anything changes (the read-only check still works).

### Windows Hello PIN removal
- Windows Hello PINs are TPM-sealed to boot measurements. Disabling VBS/Secure Launch changes those measurements, which causes the blue **"Something happened and your PIN isn't available"** lockout screen.
- The tool removes the PIN **before** it can break: blocks PIN logon via policy, disables the NGC container service, and clears stale TPM-sealed containers.
- Customers simply sign in with the **account password** (Microsoft account or local password).

### Safety rails (always on, cannot be turned off)
- **Verified restore point** — a System Restore point is created *and confirmed to exist* before anything is touched. The tool refuses to run otherwise.
- **Focused backups** — BCD export, Device Guard registry export, feature inventory, and LSA state saved to a timestamped backup folder.
- **BitLocker protection** — the OS drive's BitLocker is suspended for at most **two restarts** (the disk stays encrypted) and automatically resumed afterwards. Refuses to touch boot settings if BitLocker state is unknown.
- **Protected continuation** — the restart work runs from a `ProgramData` folder locked down to SYSTEM/Administrators, driven by a SYSTEM scheduled task.
- **Two-attempt limit** — the tool can never get stuck in a restart loop.

### Smart behavior
- **Already-off detection** — if Hyper-V and VBS are already disabled, the tool says so, changes nothing, and removes itself from sign-in startup.
- **Self-cleaning startup** — the "reopen after restart" option only persists while work is genuinely in progress; it deletes itself the moment Hyper-V is confirmed off.
- **Honest failure states** — a run that stopped early shows as *Needs attention* with a specific fix in the Log, never a fake success.
- **Double-run protection** — only one window can be open, and the Run button locks while the engine is working (including a run started by an earlier window) or a continuation task exists.

### Testing page (hidden from customers)
Hidden by default. Start the console with `-Testing`, or press **Ctrl+Shift+T** in the window.
- Native **Windows Security control** that replaces tools like Sordum Defender Control:
  - *Disable* — Defender policy keys, real-time protection off, `WinDefend`/`WdNisSvc`/`WdFilter`/`WdBoot` services stopped and disabled, Security Health tray removed.
  - *Restore* — reverses everything using service start values saved before any change.
- Live status readout: Tamper Protection, real-time protection, WinDefend service state.
- If **Tamper Protection** is ON, Windows blocks most changes — the tool detects this and tells you, instead of pretending.

### UI
- Custom WPF theme matched to illusion.cx: aubergine-black canvas with a fuchsia-to-violet glow, heavy display headings and a glowing gradient call to action. Native window frame (snap, resize, Windows 11 rounded corners and shadow).
- **Status orb** that glows while Hyper-V is on, spins while work runs, and settles green when everything is off. The whole hero tints to match the state.
- **What to do now** — a numbered checklist that changes with every state: what to prepare before starting, what to expect during the restart (including the F3 firmware prompt only when it was staged), and the exact fix from the log when something stopped early.
- **Journey stepper** (Back up → Turn off → Restart → Verify) driven by the real engine events, with the current sub-step (restore point, Windows features, boot settings…) and a *Latest* line.
- **Confirm sheet**: tick *I have saved my work* and *I know my password* to enable the run. Shows what will stop working, pre-flight warnings (on battery, low disk space, BitLocker, managed PC) and the run options. **Esc** or a click outside backs out.
- **Action bar** on every page: one primary button that always does the next right thing (*Turn off Hyper-V*, *Restart now*, *Try again*, *Close*…), plus *Check this PC* (F5) and *Cancel restart* during the 30-second warning.
- **Activity** timeline, newest first, with *All / Needs attention / Failed* filters, a failure badge, *Copy for support*, *Log folder* and *Final report*.
- **Help** sheet (F1): what changes, the F3 screen, why the PIN is gone, how to undo with System Restore (with a button to open it).
- Live check: hypervisor, VBS, Credential Guard, Memory Integrity, BitLocker, management and last run.
- Respects *Show animations in Windows* and drops continuous animation under software rendering (for example Remote Desktop).

### Efficiency and robustness
- All Windows queries (CIM, scheduled task, Defender, battery, BitLocker) run on a background runspace, so the window never stalls.
- The event log is read incrementally (only new bytes) with shared file access, so the engine can always write to it.
- Single-instance window, hidden console, a clear message if the administrator prompt is declined or files were not extracted, and a crash guard that logs to `Console-UI.log` instead of closing.

---

## Setup guide

### Requirements
- Windows 10 1903+ or Windows 11 (Windows Server is not supported: it has no System Restore)
- Windows PowerShell 5.1 (built in — no installs needed)
- Administrator rights (the tool requests elevation itself)

### Steps

1. **Download** the ZIP from the [latest release](https://github.com/jestermaxdelta/hyper-v-off-tool/releases/latest) and **extract** everything into one folder. Keep all files together.
2. Double-click **`Start-HyperV-Off-Console.cmd`** and approve the **Windows administrator prompt**.
3. Follow **What to do now** on the Home page (save your work, know your account **password** — the PIN will be disabled).
4. Click **Turn off Hyper-V**, tick the two confirmations, review the options, and click **Turn off Hyper-V** again.

### What happens next
- A restore point is created and verified; settings are backed up; BitLocker is briefly suspended.
- Changes are applied, then the PC restarts (30-second warning, or restart manually with `shutdown.exe /a` to cancel).
- If a **Microsoft confirmation screen** appears during boot, approve it with the key shown (commonly **F3**).
- The tool reopens after sign-in, finishes verification automatically (up to 2 restarts), and writes the final report.
- Sign in with your **password** — the PIN option is intentionally gone.

---

## Logs and files

Everything is kept in `C:\ProgramData\Disable-HyperV-Fully`:

| File | Purpose |
|---|---|
| `Operational-Events.jsonl` | Short entries shown in the app's Log page |
| `Disable-HyperV-Fully.log` | Full technical support log |
| `Final-Status.txt` | Whether everything is off + anything left over |
| `Backup-*\` | BCD, registry, and feature baselines |
| `SecurityToggle-Backup.json` | Original Defender service start values (Testing page) |
| `Console-UI.log` | Only written if the window itself hits an unexpected error |

The Activity page has filters for **All / Needs attention / Failed**, every failure entry includes what to do next, and **Copy for support** puts the status and recent activity on the clipboard.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| "PIN isn't available" at sign-in | Expected — sign in with the account password. |
| Verification still fails after restarts | Open `Final-Status.txt`; the named failed check tells you what to fix. Domain-joined PCs may have policy re-enabling VBS. |
| Firmware prompt was declined | Run the tool again and accept the prompt (F3). |
| Defender won't start after Testing-page restore | Restart the PC, then open `windowsdefender:` from Run and let it update. |
| Feature disable errors | `DISM /Online /Cleanup-Image /RestoreHealth`, restart, retry. |

---

## Limits

- This cannot change **Intel VT-x / AMD SVM in the BIOS** — that's a vendor-specific firmware setting and is not required for the Windows hypervisor to be off.
- **Work/school policy** (Group Policy / MDM) can re-enable VBS later.
- A restore point is useful but is **not a backup of personal files**.
- The PowerShell files are **not digitally signed** — verify the ZIP before use and never run a copy from a source you don't trust.

---

## Repository layout

```
outputs/
├── Start-HyperV-Off-Console.cmd   # Launcher (double-click this)
├── HyperV-Off-Console.ps1         # WPF UI + orchestration
├── Disable-HyperV-Fully.ps1       # Engine: safety rails + disablement + verification
└── README-HyperV-Off-Console.md   # Short customer readme (README.md inside the ZIP)
```

## Publishing a new version

Go to **Actions → Release → Run workflow**, enter a version such as `v2.0.0` (format `vX.Y.Z`), and run it. The workflow builds a customer-only ZIP (launcher, both scripts, and the short readme), stamps the version into the app (shown in Help and in *Copy for support*), publishes it as a GitHub Release with its SHA-256 hash, and marks it as the latest download.
