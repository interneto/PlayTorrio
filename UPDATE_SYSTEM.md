# PlayTorrio Auto-Update System

## Overview

PlayTorrio now includes a comprehensive auto-update system that works across all platforms:

- **Windows**: Downloads and installs .exe files
- **Linux**: Downloads AppImage or .deb files  
- **macOS**: Redirects to GitHub releases page (no code signing required)
- **Android**: Downloads and installs APK files directly

## Features

✅ Automatic update check on app startup (after 3 seconds)
✅ Manual update check in Settings
✅ Beautiful update dialog with release notes
✅ "Update Now" and "Later" buttons - user has full control
✅ Download progress indicator for Android
✅ Version comparison (only shows dialog if newer version available)

## How It Works

### For Users

1. **Automatic Check**: When you launch the app, it checks for updates in the background
2. **Update Dialog**: If a new version is available, a dialog appears with:
   - Current version vs Latest version
   - Release notes (what's new)
   - Two buttons: "Later" or "Update Now"
3. **Manual Check**: Go to Settings → App Updates → "Check for Updates"

### For Developers

The system uses GitHub Releases API to check for updates:

1. Compares current version (from pubspec.yaml) with latest GitHub release tag
2. Finds the appropriate download asset based on platform:
   - Windows: `*windows*.exe`
   - Linux: `*.AppImage` or `*.deb`
   - macOS: Links to release page
   - Android: `*.apk`
3. For Android: Uses `ota_update` package to download and install
4. For Desktop: Opens browser to download page

## Setup Requirements

### 1. GitHub Releases

Your releases must follow this structure:

```
Tag: v1.0.0 (must start with 'v')
Assets:
  - PlayTorrio-1.0.0-windows.exe
  - PlayTorrio-1.0.0-linux.AppImage
  - PlayTorrio-1.0.0-android.apk
```

### 2. Version Format

Use semantic versioning in `pubspec.yaml`:
```yaml
version: 1.0.0+1
```

The system compares: `1.0.0` (ignores build number)

### 3. Android Permissions

Already configured in `AndroidManifest.xml`:
- `REQUEST_INSTALL_PACKAGES` - allows APK installation
- File provider for secure file access

### 4. macOS Note

macOS requires code signing for auto-install. Since we don't have that, the system:
- Opens the GitHub releases page in Safari
- User manually downloads and installs
- Shows a warning in the dialog explaining this

## Testing

### Test Update Check

1. Change version in `pubspec.yaml` to something lower than your latest release
2. Run the app
3. Update dialog should appear after 3 seconds
4. Or go to Settings and click "Check for Updates"

### Test "No Updates"

1. Make sure your app version matches the latest release
2. Go to Settings → Check for Updates
3. Should show green snackbar: "You're running the latest version!"

## Customization

### Change Update Check Timing

In `lib/main.dart`, modify the delay:

```dart
await Future.delayed(const Duration(seconds: 3)); // Change this
```

### Disable Automatic Check

Remove this line from `_initEngine()` in `lib/main.dart`:

```dart
_checkForUpdatesInBackground();
```

### Customize Dialog UI

Edit `lib/widgets/update_dialog.dart` to change:
- Colors
- Layout
- Button text
- Progress indicator style

## Troubleshooting

### "Failed to check for updates"

- Check internet connection
- Verify GitHub repo name in `lib/services/app_updater_service.dart`
- Make sure releases are public

### Android: "Download failed"

- Check `REQUEST_INSTALL_PACKAGES` permission
- Verify APK is in GitHub release assets
- Check Android storage permissions

### macOS: Update doesn't install

- This is expected - macOS requires manual installation
- User will be redirected to GitHub to download

## Dependencies

```yaml
package_info_plus: ^8.1.2  # Get current app version
ota_update: ^7.1.0         # Android APK installation
url_launcher: ^6.3.1       # Open browser for downloads
http: ^1.6.0               # Check GitHub API
```

## Security Notes

- All downloads are from your GitHub releases (HTTPS)
- Android APK installation requires user confirmation
- No automatic silent installs (except on rooted devices)
- Users can always choose "Later" to skip updates

## Future Enhancements

Possible improvements:
- [ ] Delta updates (only download changed files)
- [ ] Background download with notification
- [ ] Forced updates for critical security patches
- [ ] Update scheduling (install on next restart)
- [ ] Rollback to previous version
