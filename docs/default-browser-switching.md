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

For now, Switchbar favors reliability over speed.
