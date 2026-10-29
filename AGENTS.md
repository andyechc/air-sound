# AGENTS.md

## What this is

Two native apps (one macOS, one iOS) that stream the Mac's system audio to an iPhone over the local WiFi network. On the iPhone it plays through whatever route is active — speaker or connected Bluetooth/AirPlay headphones; iOS handles that routing, we only deliver the stream.

## Layout

- `project.yml` — xcodegen source of truth. **Regenerate with `xcodegen generate` after adding/removing files** (the generated `AirSound.xcodeproj` uses classic groups, not filesystem-synced ones).
- `MacApp/` — macOS sender: menu bar app (`LSUIElement`, `NSStatusItem` + `NSPopover`) whose Core Audio process tap feeds `AirSoundCore.PCMFIFO`, then Bonjour (`_airsound._tcp`) + TCP server (`NWListener`). Right-click menu stops/quits.
- `iPhoneApp/` — iOS receiver: `NWBrowser` → `NWConnection` → `AudioPlaybackEngine` (AVAudioEngine + AVAudioPlayerNode).
- `Packages/AirSoundCore/` — platform-neutral shared package: framing, `StreamSpec`, `PCMFIFO`. Has its own unit tests.
- `docs/` — static GitHub Pages site (`main` / `docs`): landing page, privacy page, optimized screenshots, icons. English, no JS or analytics. Live at `https://andyechc.is-a.dev/air-sound/` because the account's user site carries that custom domain; `andyechc.github.io/air-sound` redirects there.
- `Tools/make-icon.swift` — regenerates the app icon PNGs (iOS full-bleed 1024, macOS squircle in a transparent margin). Output is installed into both `Assets.xcassets/AppIcon.appiconset`; macOS sizes come from `sips` downscales of the 1024.

## Commands (verified on Xcode 27)

```bash
xcodegen generate                                                     # after changing project.yml or file lists
xcodebuild -project AirSound.xcodeproj -scheme AirSoundMac \
  -destination 'generic/platform=macOS' build                         # Mac target
xcodebuild -project AirSound.xcodeproj -scheme AirSoundiPhone \
  -destination 'generic/platform=iOS Simulator' build                 # iPhone target
cd Packages/AirSoundCore && swift test                                # package unit tests
```

Pass `CODE_SIGNING_ALLOWED=NO` for headless/CI-style verification builds. Daily work happens in Xcode; set a signing Team in both targets, otherwise TCC grants (audio capture) reset on every rebuild.

Release artifacts use fixed names so the site can link to `releases/latest/download/...`:

```bash
# macOS: universal, ad hoc signed, not notarized
xcodebuild -project AirSound.xcodeproj -scheme AirSoundMac -configuration Release \
  -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
codesign --force --deep --sign - AirSound.app
ditto -c -k --sequesterRsrc --keepParent AirSound.app AirSound-macOS.zip

# iOS: unsigned IPA for AltStore
xcodebuild -project AirSound.xcodeproj -scheme AirSoundiPhone -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
mkdir -p Payload && cp -R AirSoundiPhone.app Payload/AirSound.app
zip -qry AirSound-unsigned.ipa Payload
```

No Developer ID is available, so the Mac build must be ad hoc signed and the
Gatekeeper warning documented on the site. AltStore re-signs the IPA with the
user's Apple ID; a free account needs a 7-day refresh.

AltStore source manifest: `docs/altstore.json`, served at
`https://andyechc.is-a.dev/air-sound/altstore.json`. It follows the UTM-style
schema (`name`, `identifier`, `apps`, `versions`, `downloadURL`, `size`,
`minOSVersion`, etc.) and points at the latest release asset. Keep `version`,
`date`, and `size` in sync with the published IPA; the deep link is
`altstore://source?url=...`.

## Discovery lifecycle

- `MacDiscovery.start()` is idempotent and runs on launch; `IphoneModel` also
  calls `restartDiscovery()` on `scenePhase == .active` and from the "Try again"
  button. An earlier build never started the browser, which looked like a
  Bonjour failure. `browserProblem` carries the `NWBrowser` error text.
- DEBUG demo modes (`-demo`, `-demo-playing`, Mac `-demo`, `-demo-idle`) suppress
  real browsing/streaming so screenshot seeds are not overwritten.

## Decided (v1)

- Swift + SwiftUI native per platform; shared logic lives in the `AirSoundCore` SwiftPM package. Swift 5 language mode deliberately (Core Audio C interop + NW callbacks).
- macOS capture uses a **Core Audio process tap**, not ScreenCaptureKit: `AudioHardwareCreateProcessTap` (macOS 14.2+) → private aggregate device (auto-start, tap list = [tap uuid]) → `AudioDeviceCreateIOProcIDWithBlock`.
- Transport is plain TCP (ordered, reliable); Mac is the server. One `StreamSpec` JSON metadata frame, then variable-size PCM frames of LE Float32 interleaved stereo at the Mac's output-device rate. All protocol constants live in `AirSoundCore` (`_airsound._tcp`, jitter/latency trims).
- Discovery fallback ("Connect by IP"): corporate WiFi with AP isolation / VPN kills mDNS even when the Mac advertises correctly (`dns-sd -B _airsound._tcp` sees itself). The Mac window lists its non-loopback IPv4 `host:port` hints (`MacModel.reachHints`, via getifaddrs) and the iPhone has a manual `connectManually(host:port)` path bypassing Bonjour. If manual IP also fails, client-to-client TCP is blocked — use the iPhone's personal hotspot.
- v1 reads `sampleRate` once per connection (iPhone engine converts to output). Mac output-device changes mid-session require a reconnect.

## Design & visual verification

- Direction: native Apple HIG. One accent, sky blue `#0090E9`, lives in both targets' `AccentColor`; red is reserved for stop/disconnect/error. System fonts and SF Symbols only.
- Filled controls with 13–17 pt labels use the deeper `Color.airAction` `#0071B8` / `Color.airStop` `#D70015`: white on the brand sky blue is 3.4:1 and on system red 3.5:1, short of AA for normal text. The accent itself stays for icons and 8% tints (non-text, 3:1). Both shades live in the platform `ContentView.swift`.
- Both `ContentView.swift` files carry `#Preview` macros for every key state (Mac idle/streaming; iPhone discovery/playing). The previews reference DEBUG-only demo seeds, so the whole block is wrapped in `#if DEBUG`; without that, Release builds fail on `MacModel(demo:)` / `IphoneModel.demoBrowsing()`.
- DEBUG-only seeds for previews and screenshots: Mac `-demo` (synthetic streaming session) and `-demo-idle` (name set, idle), iPhone `-demo` / `-demo-playing`. They run no audio or network, and are compiled out of release.
- Mac panel is a fixed 460 pt wide `NSPopover` that sizes its height to content, so idle and streaming states stay compact.
- Self-snapshot (Mac, DEBUG): run the executable directly with `-snapshot /path/shot.png` plus `-light` or `-dark`, `-demo` or `-demo-idle`; wait ~4 s. Prefer direct exec over `open -n`, which can skip the shot on a cold launch. The app rasterizes its own window layer at 2x. This exists because headless agent runs have no Screen Recording TCC; `screencapture` and `CGWindowListCreateImage` are unavailable. Layer render needs an explicit Y flip and a painted window background or the PNG comes out mirrored/transparent. Scripted captures: check the PNG mtime changed before trusting it, and sample the primary button color to confirm the window was key (inactive windows render it gray).
- iOS screenshots: install the `Debug-iphonesimulator` app with `xcrun simctl install "iPhone 17 Pro" <app>`, launch with the demo args, then `xcrun simctl io "iPhone 17 Pro" screenshot <path>`. Set the status bar with `xcrun simctl status_bar ... override`.
- Site verification: serve `docs/` locally, then use Playwright to check horizontal overflow at 320/360/768/1024/1440, console/request errors, image loads, anchor targets, alt text, focus outlines, and `<details>` open/close. Check light and dark separately.
- Social card: `docs/assets/og.png` is 1200×630 and combines the Mac panel with the iPhone playing screen. Keep `og:image` and `twitter:image` pointed at it; after deploy, check it returns 200 as `image/png` at 1200×630. Social networks cache previews, so use their debugger to refresh after changing it.
- Regenerate the icon with `swift Tools/make-icon.swift <output-dir>` (CoreGraphics script; no external deps).

## Platform gotchas (each one was actually hit / verified at runtime)

- **System audio capture needs `NSAudioCaptureUsageDescription` in the Mac app's Info.plist.** Without it, "System Audio Recording" TCC can never be granted — all Core Audio calls succeed and the tap delivers pure zeros, silently. The prompt fires when the aggregate device starts.
- Raw PIDs don't work as tap exclusions. Translate with `kAudioHardwarePropertyTranslatePIDToProcessObject` ('id2p') and pass process **AudioObjectIDs** to `CATapDescription(stereoGlobalTapButExcludeProcesses: [AudioObjectID])` (Swift-refined init). Passing a pid gets `kAudioHardwareBadObjectError`.
- Tap audio arrives on the IOProc's **input side** (`inInputData`): Float32, 2-ch interleaved, the output-device sample rate (48 kHz), ~10.7 ms blocks. `outOutputData` stays empty.
- Xcode 27 SDK renames: `NWBrowser.Descriptor` case is `.bonjour(type:domain:)` (`.browseNetServices` is gone); `NWConnection.State.failed` carries a non-optional `NWError`; AppKit `Host` type is gone — use `SCDynamicStoreCopyComputerName` for the Mac's pretty name.
- iOS won't discover the Mac without **both** `NSLocalNetworkUsageDescription` and `NSBonjourServices` (exact `_airsound._tcp` string) in Info.plist; background playback needs `UIBackgroundModes: audio` plus `AVAudioSession` `.playback`.
- Receiver prime/jitter rules live in `AirSoundCore` (`startPlaybackSeconds`, `maxQueuedSeconds`): start the player only after ~110 ms is queued; if the backlogged queue exceeds ~3 s, stop-and-reprime rather than letting latency grow. Program PCM in received order on the connection queue — do not hop chunks to the main actor (ordering).
- Realtime-path note: the tap callback pushes into `PCMFIFO` via `OSAllocatedUnfairLock` — brief critical sections, acceptable for v1; if reworking, keep lock-free or move to a message queue, and don't allocate in the IOProc.
