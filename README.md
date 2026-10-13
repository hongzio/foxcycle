# FoxCycle

On macOS, each Firefox profile you open runs as a separate process, so the built-in ⌘\` can't cycle consistently through the windows of different profiles. FoxCycle is a menu bar app that intercepts ⌘\` / ⌘⇧\` **only while Firefox is frontmost** and cycles through the standard windows of every profile in one fixed order (a ring).

- ⌘\` in other apps is left alone.
- Uses only public APIs (Accessibility, CGEventTap). No network access, no access to browser data or profile directories, and no keystroke logging.

## Requirements

- macOS 14 or later (verified on macOS 27.0.1, Apple silicon; not run on an Intel Mac)
- Stable Firefox (`org.mozilla.firefox`)
- Only when building from source: Swift 6 toolchain (Xcode or Command Line Tools)

## Install (Homebrew)

```sh
brew trust hongzio/tap   # Homebrew 7 doesn't load untrusted third-party taps
brew tap hongzio/tap
brew install --cask foxcycle
```

- Installs to `/Applications/FoxCycle.app`. Start it with `open -a FoxCycle` after installing.
- The first launch shows a permission prompt. On macOS 27 it is called "Device Control and Data Access".
- Once allowed, FoxCycle is listed under **System Settings → Privacy & Security → Accessibility**. That one permission is enough; Input Monitoring isn't needed.
- To start it at login, turn on **Start at Login** in its menu. It then appears as FoxCycle under **System Settings → General → Login Items**, where it can also be turned off.
- The app is self-signed and not notarized, so the cask removes the quarantine attribute when installing.

### Updating

```sh
brew upgrade --cask foxcycle
```

- This quits the running FoxCycle. The new version doesn't start by itself; start it again with `open -a FoxCycle`. Homebrew 7 runs cask install steps in a sandbox, where apps can't be launched.
- The permission is tied to the signature (bundle ID + certificate), not to the path. Every release is signed with the same certificate, so updating doesn't require granting it again.

### Permission problems and resetting

- If the menu shows "Not Granted" while System Settings shows it on, the signature has changed (for example, the certificate was recreated). Remove FoxCycle (−) from the Accessibility list, then launch it again and allow it.
- It can also be reset from the command line: `tccutil reset Accessibility com.hongzio.foxcycle` (not yet tried on macOS 27)
- If the event tap times out repeatedly (3 times in 10 seconds), FoxCycle stops intercepting and shows Retry in the menu. Until then, ⌘\` does what macOS does by default.

### Uninstalling

```sh
brew uninstall --cask foxcycle          # add --zap to also remove the Enabled setting (plist)
tccutil reset Accessibility com.hongzio.foxcycle   # remove it from the Accessibility list
```

- If Start at Login is on, turn it off in the menu before uninstalling. Whether it stays in the Login Items list after the app is deleted hasn't been checked.

## Behavior

| Situation | Behavior |
|---|---|
| Firefox is frontmost with 2 or more windows to cycle | ⌘\` next window, ⌘⇧\` previous window |
| Another app is frontmost / only 1 Firefox window / disabled / no permission | Not intercepted (macOS default) |
| ⌘\` held down | Switches once on the initial press, then nothing while it is held |
| Pressed again while a switch is in progress | Ignored (until the activation call returns, usually 10–130ms) |
| ⌃ or ⌥ also held | Not intercepted |

### Ring order
- Set by discovery order (profile launch order, then window order within a profile).
- New windows are added to the end of the ring, and only closed windows are removed. Focus changes don't change the order.
- Minimized windows and windows of a hidden (⌘H) profile keep their place in the ring but are skipped while cycling.

## Menu
- Enabled: turns the feature on or off. The setting is saved.
- Start at Login: launch at login. macOS owns this state, so changes made under Login Items in System Settings show up in the menu too. If it was turned off there, the item reads "approve in System Settings" and opens that pane when chosen.
- Permission status, and a shortcut to System Settings
- Number of Firefox windows available to cycle
- Quit

## Diagnostics

```sh
/usr/bin/log stream --style compact --level debug --predicate 'subsystem == "com.hongzio.foxcycle"'
/usr/bin/log show --last 1d --predicate 'subsystem == "com.hongzio.foxcycle" && category == "metrics"'
```

- In zsh, `log` is a shell builtin, so run it as `/usr/bin/log`.
- Logs contain only window tokens (`W3`), PIDs, directions and latencies. Window titles, URLs and keystrokes aren't logged.
- Every 30 minutes and on quit, FoxCycle logs a `metrics` summary: tap callback time, p50/p95 of switch and focus-confirmation latency, counts per outcome, CPU and memory. The summary is at notice level, so it is stored on disk and can be read later with `log show` without `log stream`. The percentiles' sample count records how many keys were pressed in those 30 minutes (not which keys).
- Instruments' Points of Interest shows `switch` intervals and `confirmed` events.

## Development

### Building from source

```sh
scripts/create-signing-identity.sh   # once: create a local signing certificate
scripts/build-app.sh                 # build and sign build/FoxCycle.app
open build/FoxCycle.app
scripts/test.sh                      # unit tests (Swift Testing)
```

- Rebuilds are signed with the same certificate, so the permission is kept.
- Development builds use the same bundle ID as the Homebrew install. Quit the installed copy before running a development build, and run only one at a time.
- Turning on Start at Login in a development build registers `build/FoxCycle.app` as the login item.
- Why `scripts/test.sh` exists: with only the Command Line Tools installed, the Swift Testing macro plugin path has to be passed explicitly. With Xcode it is equivalent to `swift test`.
- `ARCHS="arm64 x86_64" scripts/build-app.sh`: universal binary
- `BENCH=1 scripts/build-app.sh`: bench build (`build/FoxCycleBench.app`) that measures latency and input handling with synthetic input

### Signing certificate

`create-signing-identity.sh` creates a self-made code signing certificate in a **dedicated keychain** (`~/Library/Keychains/foxcycle-signing.keychain-db`). The keychain password is kept in `~/.config/foxcycle/` (mode 600). The keychain isn't added to the search list. To remove it:

```sh
security delete-keychain ~/Library/Keychains/foxcycle-signing.keychain-db
rm -r ~/.config/foxcycle
```

### Releasing

```sh
scripts/release.sh 0.1.0   # tag, GitHub release (universal app), and the cask update in the tap (~/Projects/homebrew-tap)
```

- Can only be run on the Mac that holds the signing certificate above. Signing with a different certificate would make users grant the permission again.
- The cask template is `packaging/foxcycle.rb`.

### Code layout

| Path | Contents |
|---|---|
| `Sources/FoxCycleCore` | Pure logic: ring, shortcut matching, switch policy. No AppKit or AX dependencies; covered by unit tests |
| `Sources/FoxCycle/App` | App lifecycle, menu bar, permission, screen lock detection |
| `Sources/FoxCycle/Keyboard` | Event tap (dedicated thread) |
| `Sources/FoxCycle/Firefox` | Process monitoring, AX window registry (dedicated thread + AXObserver) |
| `Sources/FoxCycle/Switching` | Switch queue, window activation |
| `Sources/FoxCycle/Diagnostics` | Logging, metrics summaries, bench (bench build only) |
| `Sources/FoxCyclePoC` | Phase 0 measurement tool (`foxcycle-poc list / bench / tap`), no longer maintained |
| `packaging` | Homebrew cask template (`Casks/foxcycle.rb` in `hongzio/homebrew-tap`) |

## Known limitations

- Other Spaces, full screen, Stage Manager and multiple displays aren't guaranteed to work.
- A window moved to another Space is treated as closed, so it may be re-added at the end of the ring when it comes back. The same happens when going to another app's full-screen Space and back. Screen lock is the exception: the ring is kept.
- Switching to another window of the same profile can take 0.1–0.2s because of how Firefox handles it, which is slower than switching across profiles.
- Turning Enabled off or losing the permission clears the ring. Turning it back on rediscovers the windows from scratch, so the window order within a profile may differ from before.
- Keys are matched by physical key (the grave key on US ANSI, keycode 50). ISO and JIS keyboards haven't been tested.
- Only stable Firefox (`org.mozilla.firefox`) is supported.
