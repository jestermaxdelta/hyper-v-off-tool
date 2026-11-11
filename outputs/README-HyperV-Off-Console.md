# Hyper-V Off Tool

This tool turns off Hyper-V, VBS, Credential Guard, Memory Integrity, and the
Windows features that depend on the Microsoft hypervisor.

## How to use it

1. Right-click the ZIP and choose **Extract All**. Keep all the files together.
2. Double-click `Start-HyperV-Off-Console.cmd`.
3. Approve the Windows administrator prompt.
4. Follow **What to do now** on the Home page. In short: save your work, close
   other apps, and make sure you know your Windows account **password**.
5. Click **Turn off Hyper-V**, tick the two confirmations, and click
   **Turn off Hyper-V** again.

The PC may need to restart up to twice. The tool carries on by itself and the
window reopens after you sign in. If Windows shows a Microsoft confirmation
screen while the PC starts, press the key shown on screen. This is usually F3.

The Home page always tells you what to do next, and the button at the bottom
right always does the next right thing (for example **Restart now** or
**Try again**). Press **F1** for help at any time.

## Requirements

- Windows 10 (version 1903 or later) or Windows 11.
- Windows Server is not supported: it has no System Restore, so the tool cannot
  create the restore point it needs. The window tells you this before anything
  changes.

## Safety checks

- A new restore point must be created and confirmed before anything is changed.
- The current boot and security settings are saved first.
- BitLocker is paused only for the required restart window and then turned back on.
- Restart work runs from a folder that only administrators and SYSTEM can change.
- Any partly prepared restart files are cleaned up if something fails.
- The tool stops after two restart attempts, so it cannot get stuck in a loop.

## How to undo it

Open **Help** in the tool and click **Open System Restore**, or run
`rstrui.exe`. Choose the restore point named
"Before disabling Hyper-V and VBS". A restore does not affect personal files.

## Logs and saved files

The tool keeps its log and recovery files here:

`C:\ProgramData\Disable-HyperV-Fully`

- `Operational-Events.jsonl` contains the short entries shown on the Activity page.
- `Disable-HyperV-Fully.log` contains the technical support log.
- `Final-Status.txt` says whether everything was turned off and lists anything left.
- `Backup-*` folders contain the saved boot and security settings.

If something fails, the Home page names the fix and the Activity entry says what
to do next. To ask for help, click **Copy for support** on the Activity page and
paste it into your message.

## Smart behavior

- If Hyper-V and VBS are **already off** when you start the tool, it says so,
  changes nothing, and removes itself from sign-in startup.
- The "Open this window after restarting" option only reopens the window while
  work is still in progress. As soon as Hyper-V is confirmed off, that entry is
  removed automatically.
- A previous run that stopped early is shown as "Needs attention" instead of
  looking like a fresh start, together with what to fix.
- Only one copy of the window can be open at a time.

## About your sign-in PIN

This tool also **disables Windows Hello PIN sign-in** on purpose. PINs are
sealed to the PC's TPM using boot measurements, and turning off Hyper-V/VBS
changes those measurements. That is what causes the blue
"Something happened and your PIN isn't available" screen. With the PIN removed
ahead of time, you simply sign in with the account password (the Microsoft
account or local password) and the PIN option is not offered.

## A few limits

- This cannot safely change Intel VT-x or AMD SVM settings in the BIOS or UEFI.
- Work or school policies may turn VBS back on later.
- A restore point is useful, but it is not a backup of personal files.
- The PowerShell files are not digitally signed. Check the ZIP hash before use and
  do not run a copy from someone you do not trust.
