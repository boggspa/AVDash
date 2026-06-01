# Vendor and Local Dependencies

This directory is for checked-in source snapshots only. Do not put generated
frameworks, DerivedData, SwiftPM checkouts, or tool caches here.

Current dependency layout:

- `Vendor/AVCMeterKit/` is a checked-in source snapshot. The normal
  PodcastPreview build does not read it directly.
- Release framework builds use `Scripts/build_avcmeterkit.sh`, which expects an
  AVCMeter checkout at `../AVCMeter` by default, or at `AVCMETER_ROOT`.
- FireWireNetBridge is treated as a sibling source checkout rather than a
  vendored tree. `Scripts/build_firewirenetbridgekit.sh` expects it at
  `../FireWireNetBridge` by default, or at `FIREWIRE_NET_BRIDGE_ROOT`.
- `PodcastPreviewShared/` is the in-repo local Swift package used by the Xcode
  project.
- GRDB is a remote SwiftPM dependency pinned in
  `PodcastPreview.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

License rule:

- Checked-in vendor snapshots are covered by the repository license unless a
  more specific license file is present inside the snapshot directory.

Safe cleanup targets:

- `.avcmeterkit-build/`
- `.firewirenetbridge-build/`
- `.derivedData*/`
- `.spm-cache/`
- `.module-cache/`
- `.build/`
- `build/`
- `VendorBuild/`

Future rule: if a dependency must be preserved in the repository, keep it under
`Vendor/<Name>/` with a short note here. If it can be rebuilt or re-resolved,
keep it ignored and outside `Vendor/`.
