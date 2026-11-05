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

The button shows the session at a glance: plain glass when off, and a coloured disc with its own symbol while holding, moving or paused. While a route plays, a ring around it fills with progress. Drag it anywhere, or throw it: it lands on the side you threw it toward and remembers its spot. Push or flick it into the left or right edge to **tuck** it away as a small tab (which still shows route progress), and tap the tab to bring it back. After a few seconds idle it fades back so it stays out of the way.

**Touch and hold** the button for quick actions without opening the picker. The menu shows the live status, a **Slower · Pause · Faster** row while a route plays (it stays open so you can tap several times), **Stop and hold here**, **Apply last location** when off, **Open LSpoof**, **Tuck into edge**, and **Turn off** when on. VoiceOver offers the same actions, plus moving the button, as custom actions.

The shortcut is **at least three fingers held for 0.8 seconds**. Releasing below three touches cancels the hold. Dismissing with fingers held does not immediately reopen the picker; the shortcut waits for release. Opener visibility and presentation are tracked per scene and survive a background/foreground cycle.

---

## Choose a location

The picker has three workspaces: **Location**, **Route**, and **Saved**. The map fills the sheet, with the status header, the place card and the footer floating over it on glass (Liquid Glass on iOS 26, a blur material before that). The header shows what is applied now, separately from your preview; touch and hold it to copy the held coordinates. Main actions and Turn off stay in the footer.

1. Search for a place, tap the map to drop a pin (double-tap still zooms), drag a pin, or choose **Coordinates**.
2. Review the place and coordinates on the map; dropped pins get a street name when one is found. **Coordinates** opens a screen with one field that reads decimal pairs, degrees-minutes-seconds (`48°51'29.6"N 2°17'40.2"E`) and Apple Maps, Google Maps or Waze links, plus separate latitude and longitude fields with N/S and E/W toggles. Drag its map to fine-tune the spot (Option-arrow keys nudge it on a keyboard), with Undo. Input accepts negative values, native digits, and decimal points or commas; errors appear beside the field with a symbol. Typing does not rewrite the live input.
3. Tap **Apply location** (or **Replace location** when active). This stops any moving/paused route and applies the selected point. Close the picker to return to the app.

**Turn off** always disables spoofing. Remember last selection only keeps the coordinate available to preview and apply again; turning it off forgets that kept coordinate.

Search suggests places as you type, with the matching text in bold, the distance and direction from the map centre, and category shortcuts (Coffee, Restaurants, Hotels, Parks and more) before you type. Pasted coordinates and map links become a **Use …** row. When nothing is found, **Search a wider area** retries over a larger region.

Coordinates and saved places remain usable when online search or directions are unavailable. Map errors provide Retry; search errors retain instructions for trying again or entering coordinates.

## Build and play a route

1. Choose **From** and **To** using search, coordinates, a saved place or the map. **Add stop** inserts up to **10 stops** between them; each stop's menu can change, move earlier or later, or remove it. The **Map taps** selector (From / Stop / To) decides what a tap on the map sets. Pins are draggable, and **Reverse the route** flips From, To and the stops.
2. Choose a **Walking path** or **Driving path** for the route. Directions are fetched leg by leg through every stop. Changing the path type refetches them.
3. Set playback speed: Walk (5 km/h), Bike (15 km/h), Drive (50 km/h), or a custom value from 1 to 500 km/h. Bike is a speed preset, not a cycling-directions API. Imported tracks with times also offer **Recorded**, which replays the trip at its own pace.
4. With stops, each leg (From to the first stop, stop to stop, the last stop to To) can be travelled its own way, for example drive to a car park, walk to a stop, then drive on. A row under From and under each stop shows how the next leg goes, with a walking or car marker on the line and its path and speed; tap it, or open **Next leg** in the stop's menu, to choose that leg's **Walking path** or **Driving path** and its speed: **Route speed** (the playback speed above), Walk, Bike, Drive or a custom value. Choosing a path the route doesn't use also sets the matching speed (Walk 5 km/h, Drive 50 km/h), which you can change. Changing one leg's path looks up only that leg again; a speed change needs no lookup and applies right away, even while the route plays. Legs left on the route's path and speed follow the route when those change.
5. **Motion** picks **Steady speed** or **Smooth** (Gentle, Normal or Sporty): smooth motion speeds up from a stop, slows for corners and brakes before stops and the destination. Where one leg's mode differs from the next (walking and driving), smooth motion comes to a stop at the change and sets off again at the new leg's pace, and each leg speeds up and brakes like its own mode.
6. **Wait at each stop** pauses at every stop for 15 seconds to 5 minutes, or a custom time.
7. **Finish in** solves the speed for you: **Match Apple Maps** uses Apple's arrival estimate, **As recorded** keeps a track's own timing, and **Finish in…** takes a trip time in minutes (waits included). It changes the route speed; legs with their own speed keep it, and when every leg has its own speed there is nothing for it to change.
8. **Start route** applies the preview. A new route draft leaves the applied session running; **Replace with this route** confirms replacement and starts at From.

While a route plays, a card at the top of the Route tab shows the time left in large type, the current speed, the arrival time, distance done and to go, and a progress bar with the stops marked. The planner folds into one line (**Edit route** opens it again; **Done** folds it). On the map, a new route draws itself in, the part already travelled turns grey, and passed stops turn into checkmarks. Removing a stop can be undone. **Slower** and **Faster** change its speed live without restarting it (on a leg with its own speed they step that leg's speed, and the card says **on this leg**), and changes to motion, waits or speed apply to the route that is playing. The time left, **Finish in** and the exported files all time each leg at its own speed, the same way playback does. The applied position has its own marker. Progress shows remaining distance and estimated time, and counts down while waiting at a stop. **Pause/Resume**, **Hold here**, and **Turn off** have distinct effects. Route controls remain available from Location and Saved through a labeled menu.

Paused samples report zero speed. Leaving the app pauses playback, and it resumes when you return; a route you paused yourself stays paused. With **Keep routes moving in the background** on in Settings, playback keeps going for as long as iOS keeps the app running in the background (for example, an app that has background location). iOS still suspends most apps, and a suspended route continues from where it was when the app wakes. Completion holds and persists the destination even with the picker closed. **Replay route** restarts its retained path during the process lifetime. Relaunch restores the last checkpoint as a held location, without resuming a route. Host callback frequency still depends on the host’s location-manager activity.

Search and directions requests are canceled and invalidated when inputs change, the workspace changes, the picker closes, or it backgrounds. An old response cannot overwrite a newer preview.

## Map links

Share a place or directions from Apple Maps, Google Maps or Waze, then use **Link** on the Location tab or **Import → Paste map link** on the Route tab. Short links such as `maps.app.goo.gl` are opened first. A link to one place becomes a location (or the selected endpoint on the Route tab); a directions link fills From, the stops and To, and picks the walking or driving path and speed from the link. A link that starts at "My location" uses the applied location, or your real location, or asks you for From. Only the first 10 stops are kept.

**Share route** sends the route back out as an Apple Maps, Google Maps or Waze link. Google Maps keeps From, To and up to 9 stops, and Waze keeps only the destination. A link has one travel mode for the whole trip, so it uses the first leg's (Waze always drives); when the legs differ, the share menu says so under the Apple Maps and Google Maps links. Apple Maps keeps every stop, but the device that opens the link needs iOS 18.4 or later to show them.

## Import and export GPX, TCX and FIT

**Import → Open GPX, TCX or FIT file…** plays back a recorded trip. Track points are used first, then route points, then waypoints. Tracks with times can play at the recorded pace, sped up or slowed down by **Finish in**.

**Share route → Export** writes the route as GPX, TCX (for Garmin and Strava) or a FIT activity, timed at the playback speed, motion and waits you chose, with each leg at its own speed. A file names one activity; with mixed legs it is the longest leg's. The exports were checked with Garmin's FIT SDK and common GPX and TCX readers.

## Schedule

The clock button next to **Apply location** / **Start route** schedules the current location or route to start later, optionally turn off at a set time, and repeat every day. Quick choices such as **In 15 min** or **In 1 hour** fill the times, and a summary at the top says when it starts and ends. When something is scheduled, the clock button shows a dot; tap it to see the summary, **Change** the schedule, or **Cancel schedule** (with Undo, unless a scheduled route has already started).

iOS only lets LSpoof act on time while the app is open, or running in the background. If the app is closed at the start time, a scheduled location is applied when you next open it, and a scheduled route is skipped if it is more than 15 minutes late. The picker tells you when a start was late or missed.

## Saved places

- Select a saved or recent place to return to Location with an explicit preview; Apply commits it.
- **Save place** asks for a name. New saves stop at 50 with visible feedback; existing places are never evicted. Valid legacy entries above 50 remain intact, and additions stay blocked until below the limit.
- Each row shows the distance, when it was saved or used, and its wander radius. Swipe right to apply, swipe left to rename or delete, and touch and hold for a map preview and a menu with Preview, Rename, Copy, Share, Wander radius, Move and Delete. Reorder mode provides drag handles and restricts moves to saved places. Mutations use persistent IDs.
- Deleting a place, removing a recent and **Clear** happen at once and offer **Undo**.
- With six or more saved places, a filter field appears; if nothing matches, you can search places for the same text.
- Recent history keeps up to five unique applied coordinates and uses a searched/saved name when available.
- **Wander radius** in a place's menu sets how far that place may drift while held: the Settings radius, no drift, 10 to 250 m, or a custom value up to 1,000 m. Applying the place uses its radius, and the Location tab's **Wander** chip changes it while you preview a saved place.

## Settings and accessibility

Settings contains altitude, course, held-position variation/radius, remembering, the optional real-location annotation, the floating opener, and **Keep routes moving in the background**. Held-position variation drifts slowly toward new points inside the radius at varying pace, with a little small-scale movement on top, instead of repeating one pattern. Edits stay local until **Save** in the top bar (enabled only when something changed), which explicitly updates the current session and preferences. Cancel or a swipe down with unsaved edits asks whether to save or discard them. Closing the picker leaves an applied session active and discards unapplied location/route drafts.

**Backup** exports saved places, recent locations and settings as a JSON file or to the clipboard, and restores them from either. Restoring shows what the backup contains and asks whether to merge it with what you have or replace it.

The radius has a live preview: a small street map with the wander circle drawn to scale, which you can drag to resize, next to a slider and an exact-value field. Real location uses genuine existing permission and appears separately, with its own recenter button and unavailable message. Updates stop when the picker closes, backgrounds, or shows Saved.

Controls use SF Symbols, Dynamic Type (layouts restack at accessibility sizes), wrapping labels, semantic light/dark colors with Increase Contrast variants, at least 44-point touch targets, VoiceOver names, values and custom actions, Voice Control names, keyboard-aware scrolling, Escape/back dismissal, and keyboard shortcuts (Command-1/2/3 for the tabs, Command-F to search, Command-S to save settings or a schedule). State is never shown by colour alone, and Differentiate Without Color adds symbols and outlines. Reduce Motion replaces springs and moving effects with fades, Reduce Transparency makes glass surfaces solid, and Bold Text is respected. Button/navigation text scales within bounds to keep actions reachable in compact presentations. Coordinate entry and row menus provide alternatives to map gestures and reordering drags.

The maintainer tests releases on a real device. The glass redesign (built for iOS 16 to 26) has only been compiled, not yet checked on a device; broader host/OS, VoiceOver, and multi-window compatibility requires testing.

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
