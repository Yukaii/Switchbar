# Default Browser Switching Behavior

Switchbar changes the default browser by updating the current user's Launch
Services handler plist, then forcing Launch Services to rebuild and restart.
This mirrors the approach used by `macadmins/default-browser`.

## Why Switching Is Slow

The slow part is not writing the plist. The slow part is this rebuild command:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -gc -R -all user,system,local,network
```

On the current test machine this has taken about 20-30 seconds, and one run took
about 32 seconds. Switchbar runs this off the main thread so the app should not
hang, but the system default may not visibly change until the rebuild finishes.

After the rebuild, Switchbar runs:

```sh
/usr/bin/killall lsd
```

That restarts the per-user Launch Services daemon so apps pick up the changed
handlers. During that restart, Launch Services XPC connections may briefly log
interruption messages. That is expected.

## Why System Settings Can Lag

System Settings appears to cache the displayed default browser separately from
Launch Services' active handler lookup. After a switch, opening links may use
the new browser before System Settings updates its UI. In some cases System
Settings may not update until it is reopened, Launch Services settles, or the
Mac is restarted.

## How To Verify The Actual Default

Prefer checking what Launch Services will use for a real URL:

```sh
swift -e 'import AppKit; let u = URL(string: "https://example.com")!; let a = NSWorkspace.shared.urlForApplication(toOpen: u); print(a?.path ?? "nil")'
```

You can also test by opening a URL:

```sh
open https://example.com
```

## Current Switch Flow

1. Write browser handlers to:

   ```text
   ~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist
   ```

2. Register the selected app bundle with `lsregister -f`.
3. Rebuild Launch Services with `lsregister -gc -R -all user,system,local,network`.
4. Restart `lsd`.
5. Verify the default via `NSWorkspace.urlForApplication(toOpen:)`.

Switchbar serializes these jobs. If the user clicks another browser while a
switch is running, the latest request is queued and runs after the current
rebuild finishes.

## Speed Tradeoffs

There may be ways to make switching faster, but each has a tradeoff:

- Skip the full `lsregister` rebuild: faster, but changes may not apply until
  later or after reboot.
- Run only `lsregister -f <selected app>` and restart `lsd`: faster, but may be
  less reliable after switching between browsers.
- Keep the current full rebuild: slow, but currently the most reliable path.
- Use public `LSSetDefaultHandlerForURLScheme`: fast, but can trigger macOS
  confirmation prompts or fail to update the full web-browser handler state.

For now, Switchbar favors reliability over speed. But 20-30 seconds is too
long for a user-facing action. The strategies below aim to make switching feel
fast while keeping reliability intact.

## Making Switching Feel Fast

The core insight: the plist write and `lsregister -f` are fast (under 1
second). Only the full `-gc -R -all` rebuild is slow. The plan is to avoid
the full rebuild when possible, and mask the latency when it is needed.

### 1. Optimistic UI Update

When the user clicks a browser, immediately update the UI to reflect their
choice before the backend work completes:

- Change the menu bar icon to the selected browser's icon.
- Show "Switching to Firefox..." in the status area.
- Highlight the selected browser in the menu.

This gives instant visual feedback. If the switch ultimately fails, roll back
the UI and show an error message. The user's intent is acknowledged
immediately, even if the system default takes time to catch up.

### 2. Tiered Rebuild (Fast Path With Fallback)

Instead of always running the full 20-30 second rebuild, try the fast path
first:

**Fast path** (~1-2 seconds):

1. Write browser handlers to the Launch Services plist.
2. Run `lsregister -f <selected app>` to register the bundle.
3. Run `killall lsd` to restart the Launch Services daemon.
4. Verify the default via `NSWorkspace.shared.urlForApplication(toOpen:)`.

If verification succeeds, the switch is done in under 2 seconds. This works
for the common case: switching between browsers that are already registered
with Launch Services (which most installed browsers are).

**Fallback** (~20-30 seconds):

If verification fails after the fast path, run the full rebuild:

```sh
lsregister -gc -R -all user,system,local,network
killall lsd
```

Then verify again.

This way, most switches are fast. The full rebuild only runs when the fast
path does not take effect — for example, when switching to a browser that
Launch Services has never seen, or after system updates that clear the
handler cache.

### 3. Pre-Registration at Launch

At app startup, register all known browsers with `lsregister -f`:

```sh
lsregister -f /Applications/Firefox.app
lsregister -f /Applications/Google\ Chrome.app
lsregister -f /Applications/Safari.app
lsregister -f /Applications/Brave\ Browser.app
# ... etc for each installed browser
```

This ensures every browser is in the Launch Services database before any
switching happens. When the user switches, the fast path is more likely to
succeed because the target browser is already registered. Pre-registration
also runs in the background at launch so it does not delay app startup.

### 4. Progress UX for the Fallback Case

When the full rebuild is necessary, show progress so the user knows what is
happening:

- Display a spinning indicator in the menu bar.
- Show elapsed time in the status message:
  "Rebuilding Launch Services (12s)..."
- Allow the user to dismiss the status. The rebuild continues in the
  background and the UI updates when it finishes.

This turns an opaque 20-30 second wait into a transparent one.

### 5. Implementation Order

The strategies should be implemented in this order, each building on the
previous:

1. **Optimistic UI** — immediate visual feedback with no backend changes.
   Lowest risk, biggest perceptual improvement.
2. **Pre-registration** — register all browsers at startup. Low risk,
   reduces the number of cases that need the full rebuild.
3. **Tiered rebuild** — fast path with fallback. Biggest actual speed win.
   The fallback ensures reliability is not sacrificed.
4. **Progress UX** — polish for the rare fallback case. Makes the full
   rebuild tolerable when it does happen.

## Updated Switch Flow (Proposed)

1. User clicks a browser in the menu or presses the global hotkey.
2. UI updates immediately (optimistic): menu bar icon changes, status shows
   "Switching to \<browser\>..."
3. Background task starts:
   a. Write browser handlers to the Launch Services plist.
   b. Run `lsregister -f <selected app>`.
   c. Run `killall lsd`.
   d. Verify via `NSWorkspace.urlForApplication(toOpen:)`.
   e. If verification fails, run the full `lsregister -gc -R -all` rebuild
      and `killall lsd` again, with progress updates in the UI.
   f. Verify again after the full rebuild.
4. On success: update status to "\<browser\> is now the default."
5. On failure: roll back the optimistic UI update, show an error message.
