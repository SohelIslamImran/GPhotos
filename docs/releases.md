# Release setup

CI builds and tests macOS and iOS on GitHub-hosted Xcode 27 runners. Pull requests use unsigned builds with read-only permissions and no signing secrets. The hosted iOS simulator logs search and face-index benchmarks and checks their results. The wall-clock limits are enforced in macOS CI and local iOS tests where simulator timing is more predictable.

Each merge to `main` that changes the app publishes the next patch version after the newest `vX.Y.Z` tag. Label the pull request `release: minor` or `release: major` for a bigger step. Changes only to Markdown, `docs/` or `.github/` don't release. A tag such as `v1.2.0` on a commit in `main` publishes that version instead, and a commit that already has a version tag isn't released again. Each release runs the macOS tests before signing. Hosted iOS tests gate the public unsigned IPA and the optional TestFlight upload. The version becomes the marketing version. The workflow run and attempt numbers supply the build number for the app and its extensions. Releasing a new version creates a new GitHub Release with a signed, notarized Mac DMG, an iOS IPA for self-signing, and SHA-256 checksums. Existing releases are left in place.

## Mac releases

The `macos-release` GitHub environment allows `main` and version tags and requires approval before granting access to signing secrets. Add the following under **Settings → Environments → macos-release**.

| Environment setting | Value |
| --- | --- |
| Variable `GPHOTOS_BUNDLE_ID` | Base bundle ID you control, without the `.mac` suffix. Defaults to `org.gphotosapp.gphotos` |
| Secret `APPLE_TEAM_ID` | Apple Developer team that owns the release bundle ID |
| Secret `SIGNING_CERTIFICATE_BASE64` | Base64-encoded **Developer ID Application** `.p12`, including its private key |
| Secret `SIGNING_CERTIFICATE_PASSWORD` | Password chosen when exporting the `.p12` |
| Secret `MAC_PROFILE_BASE64` | Base64-encoded **Developer ID** provisioning profile for `<base>.mac`, with Keychain Sharing |
| Secret `ASC_KEY_ID` | App Store Connect team API key ID for notarization |
| Secret `ASC_ISSUER_ID` | App Store Connect team API issuer ID |
| Secret `ASC_KEY_BASE64` | Base64-encoded `.p8` file for that key |

The Apple Developer account holder can create the [Developer ID certificate](https://developer.apple.com/help/account/certificates/create-developer-id-certificates). Register the Mac App ID and create its Developer ID provisioning profile with the Keychain Sharing capability. The Finder share extension and widgets use the Mac's team-prefixed App Group.

Send the files straight to GitHub's encrypted environment secrets from your machine. For example, run these commands with your own file paths in the repository checkout.

```sh
base64 -i developer-id.p12 | gh secret set SIGNING_CERTIFICATE_BASE64 --env macos-release
base64 -i gphotos.provisionprofile | gh secret set MAC_PROFILE_BASE64 --env macos-release
base64 -i AuthKey.p8 | gh secret set ASC_KEY_BASE64 --env macos-release
```

Enter the certificate password in the environment's secret form or in the interactive `gh secret set` prompt. Signing uses a temporary keychain on GitHub's disposable runner. The publish job gets release write permission and receives only the tested DMG, unsigned IPA, and their checksums.

After configuring secrets, merge a pull request into `main`, or tag a reviewed commit on `main` and push the tag to choose the version.

```sh
git tag -a v1.2.0 -m "GPhotos 1.2.0"
git push origin v1.2.0
```

Approve **Sign and notarize macOS** in the workflow run. The workflow checks Apple's notarization ticket and the signature before publishing. If signing or notarization fails, fix the setup and rerun the failed jobs in the same run.

## Optional iPhone and iPad releases

An [ad hoc IPA](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices) installs on devices registered with the signing team. iOS public beta distribution uses TestFlight. The optional job uploads to App Store Connect and leaves tester groups and external beta review under the maintainer's control.

Create the iOS app record in App Store Connect and register the four App IDs. Assign them all to `group.<base>`. In the `ios-release` environment, set the same settings as the Mac environment for the bundle ID, team and API key, with these iOS-specific signing values.

| Secret | Value |
| --- | --- |
| `SIGNING_CERTIFICATE_BASE64` | Base64-encoded **Apple Distribution** `.p12`, including its private key |
| `SIGNING_CERTIFICATE_PASSWORD` | Password chosen when exporting the iOS `.p12` |
| `IOS_APP_PROFILE_BASE64` | App Store Connect provisioning profile for `<base>`, base64-encoded |
| `IOS_SHARE_PROFILE_BASE64` | App Store Connect provisioning profile for `<base>.share`, base64-encoded |
| `IOS_UPLOAD_PROFILE_BASE64` | App Store Connect provisioning profile for `<base>.uploads`, base64-encoded |
| `IOS_WIDGETS_PROFILE_BASE64` | App Store Connect provisioning profile for `<base>.widgets`, base64-encoded |

Set the **repository** Actions variable `ENABLE_TESTFLIGHT` to `true` when this setup is ready. Approve the iOS deployment in the release run. When Apple processes the upload, select the build in [TestFlight](https://developer.apple.com/testflight/) and configure a tester group.
