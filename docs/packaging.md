---
summary: "Packaging, signing, and bundled CLI notes."
read_when:
  - Packaging/signing builds
  - Updating bundle layout or CLI bundling
---

# Packaging & signing

## Scripts
- `Scripts/package_app.sh`: builds host arch with ad-hoc signing by default; set `ARCHES="arm64 x86_64"` for universal. Verifies slices. Stable-certificate packaging requires explicit `CODEXBAR_SIGNING=identity` plus `APP_IDENTITY`.
- The bundled Developer ID provisioning profile and CloudKit entitlements apply only to upstream-team release builds. An alternate resolved `APP_TEAM_ID` retains its matching app/widget groups without that upstream profile; direct callers remain responsible for selecting a team consistent with their identity.
- `Scripts/compile_and_run.sh`: uses host arch; pass `--release-universal` or `--release-arches="arm64 x86_64"` for release packaging.
- `Scripts/sign-and-notarize.sh`: explicitly selects Developer ID signing, notarizes, staples, and zips (accepts `ARCHES` for universal).
- `Scripts/make_appcast.sh`: wrapper around the shared `mac-release make-appcast` helper; app metadata comes from `.mac-release.env`.
- `Scripts/changelog-to-html.sh`: converts the per-version changelog section to HTML for Sparkle.
- `Scripts/verify_packaged_app_launch.sh`: checks resource loading and AppKit liveness with a temporary home, disabled synthetic provider config, no inherited credentials, test-safe background work, and a sandbox guard against writes to the real home directory.

## Bundle contents
- `CodexBarWidget.appex` is built by `WidgetExtension/CodexBarWidgetExtension.xcodeproj` as a real macOS app extension, then bundled with app-group entitlements.
- When updating dependencies, refresh both the root `Package.resolved` and the widget workspace's `Package.resolved`, and verify their pinned revisions agree. Packaging deliberately disables automatic dependency resolution.
- `CodexBarCLI` copied to `CodexBar.app/Contents/Helpers/` for symlinking.
- SwiftPM resource bundles (e.g. `KeyboardShortcuts_KeyboardShortcuts.bundle`) copied into `Contents/Resources` (required for `KeyboardShortcuts.Recorder`).

## SSH account-sync helper targets

Remote account synchronization probes the SSH host with `uname` before sending the temporary
receiver. The macOS app helper is used for Darwin hosts; Linux hosts use a matching static helper
from `Contents/Resources/RemoteAccountSync/linux-x86_64/` or
`Contents/Resources/RemoteAccountSync/linux-aarch64/`.

The Linux helpers must be built by the Linux CLI workflow and supplied when packaging the app:

```sh
CODEXBAR_REMOTE_ACCOUNT_SYNC_HELPERS_DIR="$PWD/remote-account-sync-helpers" \
  ARCHES="arm64 x86_64" CODEXBAR_SIGNING=adhoc ./Scripts/package_app.sh release
```

The input directory uses this layout:

```text
remote-account-sync-helpers/
├── linux-aarch64/CodexBarCLI
└── linux-x86_64/CodexBarCLI
```

Each helper is transferred to the SSH host only for the operation and is removed by the remote
shell trap. A normal macOS-only package remains valid, but a Linux destination without its matching
helper reports a clear unavailable-helper error instead of attempting to execute a macOS binary.

## Releases
- Full checklist in `docs/RELEASING.md`.

See also: `docs/sparkle.md`.
