# Releasing Diskinventory

## What you supply

- **Apple Developer Program membership.**
- **A "Developer ID Application" certificate** in the login keychain. Its full name, for example `Developer ID Application: Your Name (ABCDE12345)`, is `DEVELOPER_ID_APPLICATION`.
- **The Team ID** (`TEAM_ID`), the 10-character code in the parentheses above.
- **An app-specific password** stored for notarization:

  ```
  xcrun notarytool store-credentials diskinventory-notary --apple-id <id> --team-id <TEAM_ID>
  ```

  The profile name, `diskinventory-notary`, is `NOTARY_PROFILE`.

## How to cut a release

```
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (ABCDE12345)" \
TEAM_ID=ABCDE12345 NOTARY_PROFILE=diskinventory-notary VERSION=0.2 \
scripts/release.sh
```

`DRY_RUN=1` builds for real but only prints the signing and notarization commands. `BUILD_NUMBER` defaults to the commit count.

What each step checks:

1. All three variables are set, and the identity ends in `(TEAM_ID)`. Otherwise the script exits 64.
2. `scripts/make-app.sh release` builds the app.
3. `codesign` signs with the Developer ID, a secure timestamp and the hardened runtime, then verifies the signature strictly.
4. `ditto` zips the app to `.build/Diskinventory-$VERSION.zip`.
5. `notarytool submit --wait` uploads the zip. Any status but Accepted fails the release.
6. `stapler staple` attaches the ticket, and `stapler validate` checks it.
7. `spctl --assess` confirms Gatekeeper accepts the app.
8. The stapled app is zipped again to the same path. That zip is the release.

### Verify a download

```
unzip Diskinventory-0.2.zip
spctl --assess --type execute -vv Diskinventory.app
xcrun stapler validate Diskinventory.app
```

Then open it on a second Mac that has never seen the app. It should open with no warning beyond the usual "downloaded from the internet" prompt.

## Things to know

- **Launch at login** only registers when the app runs from `/Applications`.
- **Full Disk Access** has to be granted again after the bundle ID or the signing team changes.
- The app is not sandboxed and the entitlements file is empty: hardened runtime with no exceptions. Metal shaders compile at runtime, which the hardened runtime allows.

## Sparkle (not included, Decision 28)

Updates are not built in. To add them:

1. Add the package `https://github.com/sparkle-project/Sparkle` (2.x). It is a third-party dependency and needs your sign-off.
2. Create the keys with `generate_keys`, then put `SUPublicEDKey` and `SUFeedURL` in `Info.plist`.
3. Start `SPUStandardUpdaterController` in `AppDelegate`, and add "Check for Updates…" to the app menu (`MainMenuSpec`).
4. Sign each archive with `sign_update` and host `appcast.xml`.
5. `release.sh` must then sign Sparkle's nested `Autoupdate`, `Updater.app` and `XPCServices/*.xpc` with the Developer ID before it signs the app.
