# AVDash

AVDash is a macOS app for local AV monitoring, video preview, audio routing
experiments, hardware telemetry, and trusted remote hardware monitoring.

## Requirements

- macOS with Xcode command line tools installed.
- Xcode 26.3 is the currently tested build environment.
- The main macOS app target supports macOS 11.5 and later. Companion and widget
  targets have their own deployment targets in the Xcode project.

## Build From A Fresh Clone

Resolve Swift packages and build the main app without signing:

```sh
xcodebuild \
  -project PodcastPreview.xcodeproj \
  -scheme PodcastPreview \
  -configuration Release \
  -destination 'platform=macOS' \
  build \
  CODE_SIGNING_ALLOWED=NO
```

The default public build uses only in-repository code and the pinned GRDB
SwiftPM dependency. Direct-download builds with the full audio and FireWire
feature set also need the signed sibling artifacts described below.

## Release Packaging

Developer ID distribution is handled by:

```sh
Scripts/package_release_dmg.sh --clean
```

This script is configured for the official signing owner by default. Override
the following environment variables for other Apple Developer accounts or CI:

- `TEAM_ID`
- `DEVELOPER_ID_IDENTITY`
- `MAIN_PROFILE_NAME`
- `MAC_WIDGET_PROFILE_NAME`
- `NOTARY_PROFILE`
- `BUILD_ROOT`

Public downloads should be notarized. The packaging script now fails if
`NOTARY_PROFILE` is not set, unless `--skip-notarize` is passed for an
internal-only artifact.

Full direct-download releases require the signed sibling payloads in ignored
`Artifacts/External/` and should be packaged with:

```sh
Scripts/package_release_dmg.sh --clean --include-external-artifacts
```

See `Artifacts/README.md` for the expected layout.

External payloads are copied by `Scripts/localise_external_artifacts.sh`, which
verifies source signatures, preserves or reapplies per-artifact entitlements,
and signs copied code from the deepest nested bundle outward before the main app
is sealed.

The helper build scripts expect sibling checkouts by default:

- `AVCMETER_ROOT`, defaulting to `../AVCMeter`
- `FIREWIRE_NET_BRIDGE_ROOT`, defaulting to `../FireWireNetBridge`

Build, sign, and stage those products under `Artifacts/External/` before
running a public direct-download package. Do not commit the staged signed
artifacts or private signing material.

## Local Network Feature

Remote hardware monitoring advertises and browses Bonjour service
`_ppremotehw._tcp`. The app includes the required local-network privacy strings
in `PodcastPreview/Info.plist`.

## License

This repository is released under the MIT License. See `LICENSE` and
`THIRD_PARTY_NOTICES.md`.
