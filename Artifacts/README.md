# Release Artifacts

`Artifacts/External/` is intentionally ignored. Use it for signed, versioned
payloads that should be bundled into private or direct-download release builds
without committing binaries, private signing material, or sibling repository
outputs.

AVDash direct-download builds need the signed AVCMeter and FireWire payloads in
this directory for the full production feature set. Public source clones can
still build without these staged artifacts, but those builds should be treated
as reduced local/development builds.

Supported layout:

```text
Artifacts/External/
  Frameworks/
    AVCMeterKit.framework
    AudioVisualiserConverterKit.framework
  PlugIns/
    SomeExtension.appex
  XPCServices/
    SomeService.xpc
  Library/LaunchServices/
    SomeHelperTool
  Audio/Plug-Ins/HAL/
    FireWireNetBridgeDriver.driver
  Resources/
    FireWireNetBridgeSender
  Entitlements/
    Frameworks/AVCMeterKit.framework.plist
    FireWireNetBridgeSender.plist
```

Build a release with those payloads included:

```sh
Scripts/package_release_dmg.sh --clean --include-external-artifacts
```

The packaging script runs `Scripts/localise_external_artifacts.sh` for these
payloads. That script verifies existing signatures, extracts entitlements unless
an override exists under `Artifacts/External/Entitlements/`, signs copied code
deepest-first, and then the packager re-seals the main app before signing and
notarizing the DMG.

Artifacts carrying the development entitlement
`com.apple.security.get-task-allow` are rejected. Rebuild those payloads for
release, or provide a matching entitlement override without that key.

The local helper scripts expect sibling source checkouts by default:

- `Scripts/build_avcmeterkit.sh`: `AVCMETER_ROOT`, defaulting to `../AVCMeter`
- `Scripts/build_firewirenetbridgekit.sh`: `FIREWIRE_NET_BRIDGE_ROOT`,
  defaulting to `../FireWireNetBridge`

After building, sign the release products and stage only the signed outputs in
the layout above.
