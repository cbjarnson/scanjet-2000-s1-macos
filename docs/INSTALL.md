# Manual installation, verification, and rollback

Use this only for the exact ScanJet Pro 2000 s1 and the tested macOS 27/Apple Silicon scope in the README. This is an experimental, add-only recovery procedure. No full HP installer needs to run.

## 1. Preserve your installation

Quit Image Capture and other scanner apps. In Finder, use **Go > Go to Folder** to inspect `/Library/Image Capture/Devices`.

**If `HP Scanner 4.app` already exists, stop. Do not replace, rename, merge, or delete it.** A newer or different Scanner 4 can serve other scanners. Open an issue with its version instead. The helper can identify whether it already matches the tested app.

Before changing anything, make local backup copies of `/Library/Image Capture` and `/Library/Printers/hp` (if present) into a dated folder. Keep the originals in place. Use an administrator account if Finder requires authentication. Record the backup location. Existing HP Scanner 3.app and HPScanner.app remain untouched.

## 2. Prepare the original app

From the downloaded project folder, run:

```sh
/bin/zsh scanjet-recovery.zsh check
/bin/zsh scanjet-recovery.zsh prepare
```

The helper prints `PREPARED, NOT INSTALLED:` followed by the exact app path. In Finder, use **Go > Go to Folder** to open that app's containing `Devices` folder inside the temporary preparation folder. Temporary files may be cleaned up by macOS later; finish the copy now or prepare again when needed.

## 3. Add the single app

Copy the prepared **HP Scanner 4.app** with **Command-C**. Open `/Library/Image Capture/Devices` in Finder and paste with **Command-V**. Authenticate with macOS when asked. **Cancel any Replace or Merge prompt.** Preserve the prepared copy for comparison.

Do not run the surrounding `.pkg`, modify or re-sign the HP app, remove quarantine attributes, disable Gatekeeper, or change SIP. If macOS rejects the signed app, stop and report the exact message.

Verify the installed copy:

```sh
/bin/zsh scanjet-recovery.zsh verify '/Library/Image Capture/Devices/HP Scanner 4.app'
```

Proceed only if the exact content, original HP identity, and Gatekeeper checks pass. The helper itself never asks for administrator privileges and refuses to run as root.

## 4. Refresh discovery and test

Reconnect the scanner's USB cable and reopen **Image Capture**. Select **HP ScanJet Pro 2000 s1**.

If the list stays empty, quit scanning apps, open **Activity Monitor**, choose **View > My Processes**, search for `icdd`, and quit only your own `icdd` process. macOS normally restarts it. Reopen Image Capture. This discovery refresh was necessary on the original test Mac. Do not terminate another user's process or edit caches. Save work before trying a logout/restart instead; that recovery path has not been tested here.

Load a non-sensitive sheet. Choose **300 dpi**, **Color**, **US Letter**, **PDF**, and a local destination. First test one side. Then reload paper and enable **Duplex**. Check saved page count, front/back content, orientation, and sheet order. A device appearing in the list is not proof of successful acquisition.

## Rollback: remove only the addition

1. Quit all scanner apps.
2. Verify that `/Library/Image Capture/Devices/HP Scanner 4.app` still matches the project manifest using the command above. If it differs or was later updated, stop and inspect instead of removing it blindly.
3. In Finder, move **only that app added by this procedure** to a dated recovery folder outside `/Library/Image Capture`. Authenticate if asked. Keep the copy; permanent deletion is unnecessary.
4. Reconnect USB and reopen Image Capture, refreshing your own discovery process if needed.

This procedure does not replace original drivers, so they should not need restoration. It also does not create an HP package receipt. Keep your backups. Automated installation, rollback, and reboot recovery have not been tested by this release.
