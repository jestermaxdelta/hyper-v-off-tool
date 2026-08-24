# Hyper-V Off Tool

This tool turns off Hyper-V, VBS, Credential Guard, Memory Integrity, and the
Windows features that depend on the Microsoft hypervisor.

## How to use it

1. Extract everything from the ZIP into one folder.
2. Save anything you have open.
3. Double-click `Start-HyperV-Off-Console.cmd`.
4. Approve the Windows administrator prompt.
5. Check the options, then click **Turn off Hyper-V** twice to confirm.

The PC may need to restart more than once. The tool will carry on automatically.
If Windows shows a Microsoft confirmation screen during startup, approve it with
the key shown on screen. This is commonly F3.

## Safety checks

- A new restore point must be created and confirmed before anything is changed.
- The current boot and security settings are saved first.
- BitLocker is paused only for the required restart window.
- Restart work runs from a folder that only administrators and SYSTEM can change.
- Any partly prepared restart files are cleaned up if something fails.
- The tool stops after two restart attempts, so it cannot get stuck in a loop.

## Logs and saved files

The tool keeps its log and recovery files here:

`C:\ProgramData\Disable-HyperV-Fully`

- `Operational-Events.jsonl` contains the short entries shown in the Log screen.
- `Disable-HyperV-Fully.log` contains the technical support log.
- `Final-Status.txt` says whether everything was turned off and lists anything left.
- `Backup-*` folders contain the saved boot and security settings.

The Log screen only shows useful results and things that need attention. If
something fails, the entry also tells you what to do next.

## Smart behavior

- If Hyper-V and VBS are **already off** when you start the tool, it says so,
  changes nothing, and removes itself from sign-in startup so it stops
  opening on its own.
- The "Open again after restart" option only re-opens the window while work
  is still in progress. As soon as Hyper-V is confirmed off, that entry is
  removed automatically.
- A previous run that stopped early is shown as "Needs attention" instead of
  looking like a fresh start, and the Log says what to fix.

## Testing page (not for customers)

The **Testing** page has a native Windows Security control that replaces
third-party tools such as Sordum Defender Control:

- **Disable Windows Security** applies the same class of changes: Defender
  policy keys (`DisableAntiSpyware`), real-time protection off, the
  `WinDefend` / `WdNisSvc` / `WdFilter` / `WdBoot` services set to disabled
  and stopped, and the Security Health tray icon removed from startup.
- **Restore Windows Security** reverses everything using service start values
  saved to `SecurityToggle-Backup.json` before any change.
- If **Tamper Protection** is ON, Windows blocks or reverts most of these
  changes; the tool warns you and tells you to turn it off first. This is a
  Microsoft protection and no admin tool can silently bypass it on updated
  Windows builds.

## About your sign-in PIN

This tool also **disables Windows Hello PIN sign-in** on purpose. PINs are
sealed to the PC's TPM using boot measurements, and turning off Hyper-V/VBS
changes those measurements — which is what causes the blue
"Something happened and your PIN isn't available" screen. With the PIN
removed ahead of time, you simply sign in with the account password
(the Microsoft account or local password) and the PIN option is not offered.

## A few limits

- This cannot safely change Intel VT-x or AMD SVM settings in the BIOS or UEFI.
- Work or school policies may turn VBS back on later.
- A restore point is useful, but it is not a backup of personal files.
- The PowerShell files are not digitally signed. Check the ZIP hash before use and
  do not run a copy from someone you do not trust.
