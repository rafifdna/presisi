# NetMonitor — menu bar network/latency monitor for managed Macs

A lightweight macOS menu bar app that shows internet connection status and
latency, designed to be deployed via Jamf Pro. Behavior is driven by a Jamf
Configuration Profile, so you can change the target host and thresholds without
rebuilding.

The menu bar shows a colored dot + latency:
- green = healthy, yellow = above warn threshold, red = above critical / offline
The dropdown shows status, latency, active interface (Wi-Fi/Ethernet), and last check time.

---

## 1. Build the app in Xcode

1. Create a new project: **macOS → App**. Name it `NetMonitor`.
2. Choose the **AppKit App Delegate** lifecycle (or SwiftUI — either is fine since
   we provide our own `main.swift`).
3. Delete the auto-generated entry point and UI files:
   - Delete `Main.storyboard` (and remove `NSMainStoryboardFile` from Info.plist if present).
   - Delete any `@main` App struct / generated `AppDelegate.swift` so there is **no**
     other `@main` or `@NSApplicationMain` in the project.
4. Add the two files from `Sources/`:
   - `main.swift`
   - `AppDelegate.swift`
5. In **Target → Info**, add:
   - `Application is agent (UIElement)` (key `LSUIElement`) = `YES`
   - Set **Bundle Identifier** to `com.presisi.netmonitor`
6. In **Signing & Capabilities**, select your **Developer ID Application** team
   (use Developer ID, not "Development", for fleet distribution).
7. Build (⌘B). For distribution, Archive or `xcodebuild`, then copy the produced
   `NetMonitor.app` to `./build/NetMonitor.app`.

> Tip: this app needs **no special TCC/PPPC permissions** — it only opens outbound
> TCP connections and reads network path state. So you do **not** need a PPPC
> configuration profile, just the managed-settings profile below.

## 2. Package + sign + notarize

Edit the variables at the top of `build_and_package.sh` (signing identities,
team ID, notary profile), then run it from this folder:

```bash
chmod +x build_and_package.sh scripts/postinstall
./build_and_package.sh
```

It produces a notarized, stapled `build/NetMonitor-1.0.0.pkg` containing:
- `/Applications/NetMonitor.app`
- `/Library/LaunchAgents/com.presisi.netmonitor.plist`
- a postinstall that fixes the LaunchAgent ownership and loads it for the
  logged-in user immediately.

## 3. Deploy via Jamf Pro

**A. Upload the package**
- Settings → Computer Management → Packages → upload `NetMonitor-1.0.0.pkg`
  (or upload via your distribution point / cloud).

**B. Install policy**
- Computers → Policies → New.
- Payload **Packages**: add `NetMonitor-1.0.0.pkg`, action **Install**.
- Trigger: Recurring Check-in (and/or Enrollment Complete). Frequency: Once per computer.
- Scope to your target smart group.
- (Optional) Add a **Files and Processes** maintenance step or rely on the pkg
  postinstall to bootstrap the LaunchAgent.

**C. Managed settings (Configuration Profile)**
- Computers → Configuration Profiles → New.
- Add payload **Application & Custom Settings**.
  - Easiest path: **External Applications → Custom Schema**, set the preference
    domain to `com.presisi.netmonitor`, and paste `jamf/netmonitor-schema.json`.
    This gives you a friendly form for host, port, interval, and thresholds.
  - Alternatively, use the **Upload** option with a plist matching
    `jamf/netmonitor-managed-settings.plist`.
- Scope it to the same group.

The app reads these managed keys at launch via `UserDefaults`, with the profile's
forced values taking precedence over the built-in defaults.

## 4. Verify on a test Mac

```bash
# Confirm the agent is loaded for the user
launchctl print gui/$(id -u)/com.presisi.netmonitor

# Confirm managed prefs landed
defaults read com.presisi.netmonitor
# or: cat "/Library/Managed Preferences/$USER/com.presisi.netmonitor.plist"
```

You should see the indicator in the menu bar. Changing the profile values and
re-checking in pushes new thresholds (relaunch the app to pick them up, or extend
the code to observe `UserDefaults.didChangeNotification`).

---

## Lightweight alternative (no Xcode / no notarization)

If you'd rather not maintain a native app, deploy **SwiftBar** (or xbar) via a
Jamf pkg and ship a small shell-script plugin that pings and prints the menu
text. Far less code and no signing pipeline, at the cost of a third-party host
app and a coarser ICMP-based measurement. The native app above is the more
polished and fully managed route.
