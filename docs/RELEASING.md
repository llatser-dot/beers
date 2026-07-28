# Releasing Beers

## The thing to understand first

Pushing to `main` ships nothing. Users do not compile your commits — they run a
signed, notarized `Beers.app` binary. Sparkle only ever reads one file:

```
SUFeedURL = https://raw.githubusercontent.com/llatser-dot/beers/main/appcast.xml
```

It compares `<sparkle:version>` in that file against the installed
`CFBundleVersion`. If they match, the user is told they are up to date — no
matter how many commits are on `main`. **`appcast.xml` is the release.**
Everything else exists to make the file `appcast.xml` points at real.

Two consequences worth internalising:

- Bumping `MARKETING_VERSION` without bumping `CURRENT_PROJECT_VERSION` ships
  nothing. Sparkle compares the *build* number, not the marketing string.
- `raw.githubusercontent.com` caches for roughly five minutes, so an update is
  not instantly visible even after the appcast push lands.

## Prerequisites

| What | Where it lives | Notes |
|---|---|---|
| Developer ID cert | login keychain | `Developer ID Application: Benjamin Restall (6U9UFUUR48)` |
| Sparkle EdDSA key | login keychain | Service `https://sparkle-project.org`, **account `com.llatser.listen`** |
| Notarization creds | *not currently stored* | See "Notarization" below |
| `sign_update` | Sparkle SPM artifact | `.../SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update` |

The Sparkle key is stored under the **old** `com.llatser.listen` bundle ID, from
before the Beers rename. Every `sign_update` / `generate_keys` call therefore
needs `--account com.llatser.listen`, or the tool reports
`ERROR: No existing signing key found!` and looks, misleadingly, like the key is
gone. Confirm the key still matches the app before trusting a release:

```sh
generate_keys -p --account com.llatser.listen
# must equal SUPublicEDKey in Beers/Info.plist
```

If those two ever disagree, stop. A mismatched signature makes the update fail
silently on the user's machine.

## Manual release

### 1. Bump both version numbers

In `project.yml`:

```yaml
MARKETING_VERSION: "1.3.2"
CURRENT_PROJECT_VERSION: "132"   # monotonic; 1.3.2 -> 132
```

### 2. Pass the readiness gate

`release-check.sh` requires a **clean worktree**, so stash the bump for the run:

```sh
git stash push project.yml
./scripts/release-check.sh
git stash pop
```

It checks LFS objects, the polish/sanitiser smokes, the no-Ollama binary gate,
and an unsigned arm64 build.

### 3. Archive and export — **never `xcodebuild build`**

```sh
xcodegen generate
xcodebuild -project Beers.xcodeproj -scheme Beers -configuration Release \
  -archivePath "$BUILD/Beers.xcarchive" archive
xcodebuild -exportArchive -archivePath "$BUILD/Beers.xcarchive" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$BUILD/export"
```

with `ExportOptions.plist` set to `method: developer-id`, `signingStyle: manual`,
`teamID: 6U9UFUUR48`.

Using the plain `build` action instead looks like it works — it reports
`BUILD SUCCEEDED`, the app is Developer ID signed, hardened runtime is on, the
timestamp is present, and `codesign --verify --deep --strict` passes. Apple then
rejects it, for two reasons neither of those checks can see:

- **`com.apple.security.get-task-allow`.** The `build` action injects this
  debugging entitlement automatically. It is not in `Beers.entitlements`, so it
  is invisible in the source tree. `exportArchive` strips it.
- **Nested Sparkle binaries.** `Sparkle.framework/Versions/B/Autoupdate` and
  `.../Updater.app` keep their upstream signatures — `build` does not re-sign
  inside the SPM framework. `exportArchive` re-signs them with Developer ID.

Verify all three before spending a notarization round-trip on it:

```sh
codesign -d --entitlements - --xml "$APP" | grep -c get-task-allow   # must be 0
for b in Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate \
         Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app; do
  codesign -dv --verbose=2 "$APP/$b" 2>&1 | grep -E "^Authority=Developer ID|^Timestamp="
done
codesign --verify --deep --strict "$APP"
```

`xcodebuild` registers the built app with LaunchServices. Unregister it when you
are done or the orphan records accumulate into duplicate Beers rows in
System Settings > Privacy & Security — the same failure `release-check.sh`
guards against in its own cleanup:

```sh
source scripts/lib/lsregister.sh
unregister_apps_under "$BUILD"       # before deleting the build dir
purge_orphan_registrations           # sweeps records whose path is already gone
```

### 4. Notarize, then staple

```sh
ditto -c -k --sequesterRsrc --keepParent "$APP" "$BUILD/Beers-1.3.2.app.zip"
xcrun notarytool submit "$BUILD/Beers-1.3.2.app.zip" \
  --keychain-profile beers --wait
xcrun stapler staple "$APP"
```

**Order matters.** Stapling writes the notarization ticket *into the app*, which
changes its bytes. So you must re-zip afterwards, and sign *that* zip:

```sh
rm "$BUILD/Beers-1.3.2.app.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$BUILD/Beers-1.3.2.app.zip"
```

Signing the pre-staple zip is the classic way to ship an update that fails its
signature check on every user's machine.

Confirm the ticket is attached, offline:

```sh
xcrun stapler validate "$APP"
spctl -a -t exec -vv "$APP"    # expect "accepted", "source=Notarized Developer ID"
```

### 5. Sign the zip for Sparkle

```sh
sign_update --account com.llatser.listen "$BUILD/Beers-1.3.2.app.zip"
```

Outputs the `sparkle:edSignature` and `length` for the appcast. Use the printed
`length` verbatim — it must be the real byte count of the uploaded file.

### 6. Publish the release

```sh
gh release create v1.3.2 "$BUILD/Beers-1.3.2.app.zip" \
  -R llatser-dot/beers -t "Beers v1.3.2 — <name>" -F notes.md
```

Upload before touching the appcast. If the appcast points at a URL that 404s,
every user who checks in that window gets a failed download.

### 7. Update the appcast — this is the step that ships

Add a new `<item>` to `appcast.xml` with the new version, URL, signature and
length, then:

```sh
git commit -am "Release 1.3.2" && git tag v1.3.2 && git push && git push --tags
```

The update goes live when *this push* lands (plus the raw cache delay), not when
the code was pushed.

## Notarization credentials

The profile already exists and does not need recreating:

```
profile:   Beers Notarization 2026      <- note the spaces
apple-id:  [redacted]  <- the outlook address, not the gmail one
team-id:   6U9UFUUR48
```

Stored 22 July 2026. Use it as `--keychain-profile "Beers Notarization 2026"`.

**Do not go looking for this in the keychain with `security`.** `notarytool`
stores the profile under the service `com.apple.gke.notary.tool`, and any
`grep -v com.apple` filter — the obvious way to cut Apple's noise out of a
keychain dump — hides exactly this item. That mistake has now cost a full
release cycle. The only reliable check is to ask `notarytool` itself:

```sh
xcrun notarytool history --keychain-profile "Beers Notarization 2026"
```

If it ever does need recreating, the password is an **app-specific password**
from appleid.apple.com, not the Apple ID password. For CI, an App Store Connect
API key (`.p8`) is better: scopeable and revocable, where an app-specific
password is tied to the whole Apple ID and is silently revoked whenever the
Apple ID password changes.

## Automated release

`.github/workflows/release.yml` runs the whole flow on a `v*` tag push. See that
file's header for the four required secrets. The manual path above remains the
fallback, and is worth doing by hand at least once so the CI failures are
legible.
