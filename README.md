# LSpoof

Select the location reported by covered APIs inside a compatible sideloaded iOS app.

The dylib is designed for load-time injection into a sideloaded IPA. Covered Core Location and MapKit reads report a selected coordinate or a simulated route. It runs inside the host process; app compatibility requires testing with that host.

## Download and update

Download **LocationSpoofer.dylib** from the [latest release](https://github.com/ezzuldinSt/LSpoof/releases/latest). The binary targets **arm64 devices on iOS 16.0 or later**.

Use your usual IPA injection and signing tool to add the dylib to the app. To update, replace the previous embedded copy, re-sign the modified IPA, and reinstall it using that tool. Adding the dylib to an app does not change other apps' locations.

---

## How It Works

The library is injected into a third-party iOS app via `LC_LOAD_DYLIB` (load-time Mach-O patching). A process-lifetime session controller owns Off, Holding location, Moving, and Paused state. Location wrappers consume a coherent session snapshot, and opening the picker preserves the active session.

Supported hooking targets:

- `CLLocationManager.setDelegate:` → non-system delegates implementing `locationManager:didUpdateLocations:` or the legacy `locationManager:didUpdateToLocation:fromLocation:` receive simulated locations while the session is active. Both legacy arguments use simulated history.
- `CLLocationManager.location` — the synchronous getter.
- `MKUserLocation.location` — the covered MapKit getter.

When Off, the wrappers forward original values. Authorization status and Location Services availability remain genuine. The picker's optional real-location annotation uses its own manager and starts updates only with existing permission; it does not request authorization.

Touch detection wraps `UIApplication.sendEvent:` and captures the original implementation. Lifecycle installation handles custom UIApplication subclasses. Presentation belongs to the initiating foreground window/scene.

**Coverage limits:** Swift `CLLocationUpdate.liveUpdates()`, `CLBackgroundActivitySession`, heading callbacks, visits/geofences, system-framework delegates, telephony/WiFi/IP-based geolocation, and server-side IP checks are outside these hooks. The library does not provide a device-wide GPS override.

---

## Open the picker

Tap the floating **Location** button. It is enabled by default and can be hidden in Settings. The opener only receives touches on its own button and does not take the app’s key window.

The shortcut is **at least three fingers held for 0.8 seconds**. Releasing below three touches cancels the hold. Dismissing with fingers held does not immediately reopen the picker; the shortcut waits for release. Opener visibility and presentation are tracked per scene and survive a background/foreground cycle.

---

## Choose a location

The picker has three workspaces: **Location**, **Route**, and **Saved**. Its header shows the applied session separately from your preview. Main actions and Turn off stay in the footer.

1. Search for a place, tap/drag a pin, or choose **Edit coordinates**.
2. Review the place and coordinates on the map. Coordinate input accepts negative values, native digits, and decimal points or commas; errors appear beside the field. Typing does not rewrite the live input.
3. Tap **Apply location** (or **Replace location** when active). This stops any moving/paused route and applies the selected point. Close the picker to return to the app.

**Turn off** always disables spoofing. Remember last selection only keeps the coordinate available to preview and apply again; turning it off forgets that kept coordinate.

Coordinates and saved places remain usable when online search or directions are unavailable. Map errors provide Retry; search errors retain instructions for trying again or entering coordinates.

## Build and play a route

1. Choose **From** and **To** using search or coordinates. The named From/To map selector determines which endpoint a tap edits. Pins are draggable; Swap endpoints reverses the draft.
2. Choose a **Walking path** or **Driving path** before **Build route**. Changing this choice after a preview refetches directions.
3. Set playback speed: Walking (5 km/h), Cycling (15 km/h), Driving (50 km/h), or a custom value from 1 to 500 km/h. Speed changes movement without changing the chosen path. Cycling is a speed preset, not a cycling-directions API.
4. **Start route** applies the preview. A new route draft leaves the applied session running; **Replace with this route** confirms replacement and starts at From.

The applied position has its own marker. Progress shows remaining distance and estimated time using playback speed. **Pause/Resume**, **Hold here**, and **Turn off** have distinct effects. Route controls remain available from Location and Saved through a labeled menu.

Paused samples report zero speed. Leaving the app pauses playback, and it resumes when you return; a route you paused yourself stays paused. Completion holds and persists the destination even with the picker closed. **Replay route** restarts its retained path during the process lifetime. Relaunch restores the last checkpoint as a held location, without resuming a route. Host callback frequency still depends on the host’s location-manager activity.

Search and directions requests are canceled and invalidated when inputs change, the workspace changes, the picker closes, or it backgrounds. An old response cannot overwrite a newer preview.

## Saved places

- Select a saved or recent place to return to Location with an explicit preview; Apply commits it.
- **Save place** asks for a name. New saves stop at 50 with visible feedback; existing places are never evicted. Valid legacy entries above 50 remain intact, and additions stay blocked until below the limit.
- Row menus expose Preview, Rename, Delete, Move to top, Move up, and Move down. Reorder mode provides drag handles and restricts moves to saved places. Mutations use persistent IDs.
- Recent history keeps up to five unique applied coordinates, uses a searched/saved name when available, and provides **Clear recent locations**.

## Settings and accessibility

Settings contains altitude, course, held-position variation/radius, remembering, the optional real-location annotation, and the floating opener. Edits stay local until **Save settings**, which explicitly updates the current session and preferences. Cancel or a swipe down with unsaved edits asks whether to save or discard them. Closing the picker leaves an applied session active and discards unapplied location/route drafts.

The radius has a circle preview. Real location uses genuine existing permission and appears separately, with its own recenter button and unavailable message. Updates stop when the picker closes, backgrounds, or shows Saved.

Controls use SF Symbols, Dynamic Type, wrapping labels, semantic light/dark colors, at least 44-point touch targets, VoiceOver names/state announcements, keyboard-aware scrolling, Escape/back dismissal, and Reduce Motion. Button/navigation text scales within bounds to keep actions reachable in compact presentations. Coordinate entry and row menus provide alternatives to map gestures and reordering drags.

The maintainer tests releases on a real device. The v1.2 redesign still needs a full device check; broader host/OS, VoiceOver, and multi-window compatibility requires testing.

---

## Build

Install [Theos](https://theos.dev/docs/Installation-Linux.html) and export `THEOS` to its installation directory in your shell. Then run:

```sh
make clean
make FINALPACKAGE=1 DEBUG=0
```

Release output: `.theos/obj/LocationSpoofer.dylib` (optimized, stripped, and ad hoc signed). For a debug build, run `make DEBUG=1`; its output is `.theos/obj/debug/LocationSpoofer.dylib`.

The SDK is pinned to iPhoneOS **16.5**, with an iOS **16.0** deployment target and `arm64` architecture. ARC is enabled. The Linux build has been verified with Theos revision `dd5c14bb9d91311e221d51b5bfb8c9e5948156db` and the official Linux Clang 11.1.0 toolchain. Device, injection, and native UI compatibility remain subject to iOS host testing.
