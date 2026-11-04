# LSpoof

Select the location reported by covered APIs inside a compatible sideloaded iOS app.

The dylib is designed for load-time injection into a sideloaded IPA. Covered Core Location and MapKit reads report a selected coordinate or a simulated route. It runs inside the host process; app compatibility requires testing with that host.

## Download and update

Download **LocationSpoofer.dylib** from the [latest release](https://github.com/ezzuldinSt/LSpoof/releases/latest). The binary targets **arm64 devices on iOS 16.0 or later**.

Use your usual IPA injection and signing tool to add the dylib to the app. To update, replace the previous embedded copy, re-sign the modified IPA, and reinstall it using that tool. Adding the dylib to an app does not change other apps' locations.

### Use with Google Maps

Google Maps reads location through `CLLocationManager`, which LSpoof covers, and it is the app the maintainer tests releases in.

1. Get a **decrypted** Google Maps IPA. App Store apps are encrypted, and an encrypted IPA installs but crashes or won't open once re-signed. Decrypt a copy from your own device with a decryption tool, or use one you already have the rights to.
2. Add **LocationSpoofer.dylib** with an injection tool such as Sideloadly (its "Inject dylibs/frameworks" option), Feather or Azule.
3. Sign and install the result with Sideloadly, AltStore or SideStore. A free Apple ID needs the app refreshed every 7 days.
4. Open Maps and tap the floating **Location** button.

Google sign-in, notifications and other entitlement-bound features can behave differently in a re-signed app.

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

**Touch and hold** the button for quick actions without opening the picker: **Pause/Resume route**, **Stop and hold here**, **Faster** and **Slower** while a route plays (the menu stays open so you can tap several times), **Apply last location** when off, and **Turn off** when on.

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

1. Choose **From** and **To** using search, coordinates, a saved place or the map. **Add stop** inserts up to **10 stops** between them; each stop's menu can change, move earlier or later, or remove it. The **Map taps** selector (From / Stop / To) decides what a tap on the map sets. Pins are draggable, and **Reverse the route** flips From, To and the stops.
2. Choose a **Walking path** or **Driving path**. Directions are fetched leg by leg through every stop. Changing the path type refetches them.
3. Set playback speed: Walk (5 km/h), Bike (15 km/h), Drive (50 km/h), or a custom value from 1 to 500 km/h. Bike is a speed preset, not a cycling-directions API. Imported tracks with times also offer **Recorded**, which replays the trip at its own pace.
4. **Motion** picks **Steady speed** or **Smooth** (Gentle, Normal or Sporty): smooth motion speeds up from a stop, slows for corners and brakes before stops and the destination.
5. **Wait at each stop** pauses at every stop for 15 seconds to 5 minutes, or a custom time.
6. **Finish in** solves the speed for you: **Match Apple Maps** uses Apple's arrival estimate, **As recorded** keeps a track's own timing, and **Finish in…** takes a trip time in minutes (waits included).
7. **Start route** applies the preview. A new route draft leaves the applied session running; **Replace with this route** confirms replacement and starts at From.

While a route plays, **Slower** and **Faster** change its speed live without restarting it, and changes to motion, waits or speed apply to the route that is playing. The applied position has its own marker. Progress shows remaining distance and estimated time, and counts down while waiting at a stop. **Pause/Resume**, **Hold here**, and **Turn off** have distinct effects. Route controls remain available from Location and Saved through a labeled menu.

Paused samples report zero speed. Leaving the app pauses playback, and it resumes when you return; a route you paused yourself stays paused. With **Keep routes moving in the background** on in Settings, playback keeps going for as long as iOS keeps the app running in the background (for example, an app that has background location). iOS still suspends most apps, and a suspended route continues from where it was when the app wakes. Completion holds and persists the destination even with the picker closed. **Replay route** restarts its retained path during the process lifetime. Relaunch restores the last checkpoint as a held location, without resuming a route. Host callback frequency still depends on the host’s location-manager activity.

Search and directions requests are canceled and invalidated when inputs change, the workspace changes, the picker closes, or it backgrounds. An old response cannot overwrite a newer preview.

## Map links

Share a place or directions from Apple Maps, Google Maps or Waze, then use **Link** on the Location tab or **Import → Paste map link** on the Route tab. Short links such as `maps.app.goo.gl` are opened first. A link to one place becomes a location (or the selected endpoint on the Route tab); a directions link fills From, the stops and To, and picks the walking or driving path and speed from the link. A link that starts at "My location" uses the applied location, or your real location, or asks you for From. Only the first 10 stops are kept.

**Share route** sends the route back out as an Apple Maps, Google Maps or Waze link. Google Maps keeps From, To and up to 9 stops, and Waze keeps only the destination. Apple Maps keeps every stop, but the device that opens the link needs iOS 18.4 or later to show them.

## Import and export GPX, TCX and FIT

**Import → Open GPX, TCX or FIT file…** plays back a recorded trip. Track points are used first, then route points, then waypoints. Tracks with times can play at the recorded pace, sped up or slowed down by **Finish in**.

**Share route → Export** writes the route as GPX, TCX (for Garmin and Strava) or a FIT activity, timed at the playback speed, motion and waits you chose. The exports were checked with Garmin's FIT SDK and common GPX and TCX readers.

## Schedule

The clock button next to **Apply location** / **Start route** schedules the current location or route to start later, optionally turn off at a set time, and repeat every day. A banner at the top of the picker shows what's scheduled, with **Change** to replace or cancel it.

iOS only lets LSpoof act on time while the app is open, or running in the background. If the app is closed at the start time, a scheduled location is applied when you next open it, and a scheduled route is skipped if it is more than 15 minutes late. The picker tells you when a start was late or missed.

## Saved places

- Select a saved or recent place to return to Location with an explicit preview; Apply commits it.
- **Save place** asks for a name. New saves stop at 50 with visible feedback; existing places are never evicted. Valid legacy entries above 50 remain intact, and additions stay blocked until below the limit.
- Row menus expose Preview, Rename, Delete, Move to top, Move up, and Move down. Reorder mode provides drag handles and restricts moves to saved places. Mutations use persistent IDs.
- Recent history keeps up to five unique applied coordinates, uses a searched/saved name when available, and provides **Clear recent locations**.
- **Wander radius** in a place's menu sets how far that place may drift while held: the Settings radius, no drift, 10 to 250 m, or a custom value up to 1,000 m. Applying the place uses its radius, and the Location tab's **Wander** chip changes it while you preview a saved place.

## Settings and accessibility

Settings contains altitude, course, held-position variation/radius, remembering, the optional real-location annotation, the floating opener, and **Keep routes moving in the background**. Held-position variation drifts slowly toward new points inside the radius at varying pace, with a little small-scale movement on top, instead of repeating one pattern. Edits stay local until **Save settings**, which explicitly updates the current session and preferences. Cancel or a swipe down with unsaved edits asks whether to save or discard them. Closing the picker leaves an applied session active and discards unapplied location/route drafts.

**Backup** exports saved places, recent locations and settings as a JSON file or to the clipboard, and restores them from either. Restoring shows what the backup contains and asks whether to merge it with what you have or replace it.

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

`Tests/run.sh` runs the host tests for the motion model, the track codecs, GPX/TCX/FIT reading and writing, and map links. The C tests need only a C compiler (`Tests/run.sh c`); the Objective-C tests use Foundation on macOS or GNUstep on Linux (`apt install clang gnustep-make libgnustep-base-dev libblocksruntime-dev`).

GitHub Actions runs the tests and the same release build on every push to `main`, every pull request and every `v*` tag, using the Theos revision, toolchain and SDK listed below. Each run's **LocationSpoofer.dylib** and **SHA256SUMS** are attached to the run as an artifact.

The SDK is pinned to iPhoneOS **16.5**, with an iOS **16.0** deployment target and `arm64` architecture. ARC is enabled. The Linux build has been verified with Theos revision `dd5c14bb9d91311e221d51b5bfb8c9e5948156db` and the official Linux Clang 11.1.0 toolchain. Device, injection, and native UI compatibility remain subject to iOS host testing.
