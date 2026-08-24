# Hyper-V Off Tool

A premium dark-themed Windows utility that **fully disables Hyper-V, VBS (Virtualization Based Security), Credential Guard, Memory Integrity (HVCI), Windows Hello PIN sign-in, and every Windows feature that depends on the Microsoft hypervisor** — with built-in safety rails, automatic restart handling, and a clean customer-facing UI.

Built for Windows PowerShell 5.1 (built into Windows). No dependencies, no install.

---

## Features

### Core disablement
- **Full hypervisor shutdown** — sets `hypervisorlaunchtype off` and `vsmlaunchtype off` in the boot configuration (BCD).
- **Windows features removed** — Hyper-V, Virtual Machine Platform, Hypervisor Platform, Windows Sandbox, Application Guard, Isolated User Mode, and WSL 2's hypervisor dependency.
- **VBS / Credential Guard / HVCI / System Guard / Kernel Shadow Stacks** — explicit off values written to both policy and configuration registry locations.
- **UEFI firmware lock removal** — stages Microsoft's own `SecConfig.efi` opt-out flow (the same one the DG Readiness tool uses) so firmware-locked VBS policies can be cleared. Requires pressing the key shown on screen at boot (commonly **F3**).
- **Windows Server support** — removes the Hyper-V role when run on Server SKUs.

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
- **Double-run protection** — the Run button locks while the engine is working or a continuation task exists.

### Testing page (not shown to customers)
- Native **Windows Security control** that replaces tools like Sordum Defender Control:
  - *Disable* — Defender policy keys, real-time protection off, `WinDefend`/`WdNisSvc`/`WdFilter`/`WdBoot` services stopped and disabled, Security Health tray removed.
  - *Restore* — reverses everything using service start values saved before any change.
- Live status readout: Tamper Protection, real-time protection, WinDefend service state.
- If **Tamper Protection** is ON, Windows blocks most changes — the tool detects this and tells you, instead of pretending.

### UI
- Custom WPF dark theme: gradient canvas, indigo accent with glow CTA, icon navigation, status pills, toggle switches, and a filtered activity log that only shows what matters.
- Live status: hypervisor, VBS, domain management, and last-run state, refreshed every 2 seconds.

---

## Setup guide

### Requirements
- Windows 10 1903+ or Windows 11 (client), or Windows Server
- Windows PowerShell 5.1 (built in — no installs needed)
- Administrator rights (the tool requests elevation itself)

### Steps

1. **Extract** everything from `HyperV-Off-Console.zip` into one folder. Keep all files together.
2. **Save your work** and make sure you know the account **password** (the PIN will be disabled).
3. Double-click **`Start-HyperV-Off-Console.cmd`**.
4. Approve the **Windows administrator prompt**.
5. Review the **Overview** page to confirm what is currently running.
6. Check **Options** (restart behavior, firmware opt-out, reopen-after-restart).
7. Click **Turn off Hyper-V**, then click again to confirm.

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

The Log page has filters for **All / Needs attention / Failed**, and every failure entry includes what to do next.

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
├── README-HyperV-Off-Console.md   # Short customer readme (also inside the ZIP)
└── HyperV-Off-Console.zip         # Ready-to-distribute package
```
