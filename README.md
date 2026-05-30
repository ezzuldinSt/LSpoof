# LSpoof

Override your iOS device's GPS location from inside any app — no jailbreak required.

Drop this dylib into a sideloaded IPA, and the app will report whatever coordinates you choose instead of your real location. Safari, Maps, Uber, Lyft, Pokemon GO — wherever the host app reads `CLLocation`, the spoofed value comes through.

---

## How It Works

The library is injected into a third-party iOS app via `LC_LOAD_DYLIB` (load-time Mach-O patching). On launch, it swizzles `CLLocationManager` methods so every location callback — delegate-based or synchronous — returns a user-defined coordinate instead of the real GPS reading.

Supported hooking targets:

- `CLLocationManager.setDelegate:` → delegates implementing `locationManager:didUpdateLocations:` or the legacy `locationManager:didUpdateToLocation:fromLocation:` are swizzled to inject spoofed `CLLocation` arrays.
- `CLLocationManager.location` — the synchronous getter is swizzled directly.

The gesture detection (`sendEvent:` on `UIApplication`/`UIWindow`) is reinstalled on `UIApplicationDidFinishLaunching` and `UIApplicationDidBecomeActive` to handle apps that subclass `UIApplication`.

**What is NOT hooked:** Swift `CLLocationUpdate.liveUpdates()` (iOS 17+ async sequence), `CLBackgroundActivitySession`, telephony/WiFi/IP-based geolocation, or server-side IP checks.

---

## Trigger

**Three fingers, 0.8 seconds.** Touch and hold three fingers anywhere on the screen. After 0.8 seconds the map picker appears. Lift any finger before the timer fires and nothing happens.

The gesture is disabled while the picker is visible so the host app's MapKit still works normally.

---

## The Picker

A full-sheet map UI with search, a draggable pin, and a control panel.

### Map tab

Two modes switchable via a segment control:

**Static mode** — pick a coordinate and hold it:
- Search bar with Apple MapKit autocomplete
- Interactive map with draggable pin
- Manual Lat/Lon/Altitude text fields
- Heading slider (0–359 degrees with compass direction indicator)
- **Apply Location** — persists the coordinate and enables spoofing
- **Stop Spoofing** — disables spoofing and clears saved state

**Route mode** — simulate movement along a real route:
- Tap to place start and destination markers (green/red draggable pins)
- **Get Route** fetches directions via Apple Maps
- Transport mode: Walk (5 km/h), Cycle (15 km/h), Drive (50 km/h), or Custom
- **Play** / **Pause** / **Stop** controls the simulation
- Interpolates along the polyline at 0.1 s intervals with heading computed in real time

### Bookmarks tab

Two sections:
- **Recents** — last 5 applied coordinates with reverse-geocoded names
- **Bookmarks** — saved locations; swipe to delete, long-press to rename, drag to reorder in edit mode
- Each bookmark has an inline **Apply** button for one-tap spoofing

---

## Build

```
export THEOS=/path/to/theos
make clean
make
```

Output: `.theos/obj/debug/LocationSpoofer.dylib`

Requires [theos](https://github.com/theos/theos) (Linux Makefile toolchain). SDK target is iPhoneOS 16.0, source-compatible through iOS 26. Architecture: `arm64`. ARC enabled.

