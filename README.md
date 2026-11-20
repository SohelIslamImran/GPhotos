# GPhotos

GPhotos is an independent, native macOS app for uploading photos and videos to Google Photos. Watch folders for new media, drop files or folders into the app, or send files from Finder with the share extension. Follow upload progress and retry failed transfers from Activity.

- Upload original-quality photos and videos, including recognized Live Photo pairs. New uploads are configured to count toward your Google Account storage quota.
- Browse your local and Google Photos media in one library. Search, view albums and favorites, and manage cloud items in the selected account.
- Use multiple Google accounts and choose which accounts keep a copy.
- Optionally free local space after backup. Cleanup requires a verified cloud copy and respects the app's protection settings.

GPhotos uses Google Photos' unofficial mobile interface for sign-in, uploads, and full-library sync. Google can change that interface independently of this project. GPhotos sends selected media to Google and stores account credentials in the system Keychain. It is unaffiliated with Google.

## Build from source

Install Xcode 27 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The app targets macOS 27 or later.

```sh
./scripts/build-and-run.sh macos
```

This builds without an Apple Developer account. To run a development-signed build with the Finder share extension and widgets, select your own signing team in Xcode or run the commands below with your own values.

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID GPHOTOS_BUNDLE_ID=com.example.gphotos ./scripts/build-and-run.sh macos
open .build/macos/Build/Products/Debug/GPhotosSyncMac.app
```

The Mac app, share extension, and widgets use the same team-prefixed App Group. Use an App Group your team controls. Open GPhotos, add your Google account, and choose **Folders** to set up a watched folder.

## Run the macOS tests

```sh
xcodegen generate
xcodebuild test -project GPhotosSync.xcodeproj -scheme GPhotosSyncMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

The repository also contains the iOS companion source. Use `./scripts/build-and-run.sh ios` for an unsigned simulator build.

See [third-party notices](THIRD-PARTY-NOTICES) for bundled license terms.
