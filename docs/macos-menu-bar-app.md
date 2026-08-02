# Magic Mouse Switch macOS menu-bar app

## Scope

`MagicMouseSwitchMac` is a native AppKit menu-bar application for Ranveer's
single configured Magic Mouse at `d0-c0-50-d5-10-77`. It is intentionally not a
general-purpose device manager and is not packaged as a public release.

The app bundle sets `LSUIElement` to `true`, so it has no Dock icon and does not
appear in Command-Tab. It creates one `NSStatusItem` and registers
Control-Shift-M with the public Carbon hot-key API.

## Architecture

The Swift package has three relevant layers:

- `DeviceSelectionCore` contains pure address, identity, callback-decision,
  System Settings retry, and menu-policy logic.
- `MagicMouseSwitchServices` contains the reusable in-process status, pairing,
  Accessibility, and guarded Forget services. It uses public IOBluetooth,
  AppKit, and ApplicationServices APIs.
- `MagicMouseSwitchMac` owns the status item, menu, global shortcut, popup,
  background operation coordination, single-instance check, and file logging.

`DeviceForget` and `DevicePair` remain available as command-line targets. They
retain their exact typed confirmations for manual CLI hardware tests, but call
the same reusable services as the app. The app never launches or shells out to
either executable.

## Menu and toggle state machine

The menu displays:

```text
Magic Mouse Switch
------------------
Status: Connected / Paired but disconnected / Unpaired / Unavailable
Connect / Pair Magic Mouse
Forget Magic Mouse
Toggle Magic Mouse
Refresh Status
Open Logs
------------------
Quit
```

Status is derived from a fresh `IOBluetoothDevice.pairedDevices()` read:

- exactly one valid pinned paired record with `isConnected == true` is
  `Connected`;
- exactly one valid pinned paired record with `isConnected == false` is
  `Paired but disconnected`;
- no record at the pinned address is `Unpaired`;
- enumeration, uniqueness, name, class, or state validation failure is
  `Unavailable`.

Toggle performs a second live status read on a background queue. Paired states
choose Forget; Unpaired chooses Pair; Unavailable fails without changing state.
There are no typed confirmations in the app.

An operation lock disables Pair, Forget, Toggle, and Refresh while work is
active. It also ignores repeated Control-Shift-M events and duplicate menu
commands. The status row reads `Operation in progress…` until completion.

## Safety gates

Both services preserve the proven gates:

1. Normalize the configured address and require an exact match.
2. Require a name containing `Magic Mouse`, case-insensitively.
3. Require device class `0x002580`.
4. Require exactly one eligible device record.
5. Revalidate immediately before each state-changing operation.
6. Ignore every non-pinned inquiry result.

Pair uses the existing 30-second inquiry deadline, stops immediately after the
pinned address, performs the final unpaired revalidation before the sole
`IOBluetoothDevicePair.start()`, verifies exactly one paired record afterward,
and polls connection state for up to 15 seconds. PIN, passkey, and numeric
confirmation callbacks are logged and refused rather than automatically
answered.

Forget retains the 15-second System Settings acquisition policy. Every retry
recreates the AX application and every window hierarchy. The device-row
adjacency, exact-name details sheet, exact-name confirmation text, unique Cancel
button, and unique final Forget Device button are revalidated. The final button
is pressed once only. Its immediate AX result—including the observed `-25205`
result—is logged, while disappearance of the pinned pairing record during the
20-second bounded postcondition poll remains authoritative.

## Accessibility permission flow

On first normal launch, the app checks trust off the main thread using
`AXIsProcessTrustedWithOptions` with prompting enabled. If trust is absent, it
shows a clear explanation that Accessibility is used only to verify and press
the exact System Settings controls needed to forget the pinned mouse. The alert
has an **Open Accessibility Settings** button that opens Privacy & Security →
Accessibility.

Without trust, Forget and Toggle are disabled. Pair remains available when the
live Bluetooth state is Unpaired. Trust is refreshed whenever status refreshes.

The `MAGIC_MOUSE_SWITCH_VALIDATION=1` environment variable suppresses the
first-launch system prompt and onboarding alert for a non-destructive launch
validation; it does not enable any operation or bypass a safety gate.

## Popup behavior

One reusable non-activating `NSPanel` appears at the bottom center of the screen
containing the pointer. It uses HUD material, does not activate the app, is
excluded from window cycling, and updates in place rather than stacking.

It shows these states:

- `Forgetting Magic Mouse…`
- `Magic Mouse forgotten`
- `Searching for Magic Mouse…`
- `Pairing Magic Mouse…`
- `Magic Mouse connected`
- `Operation failed`
- `Accessibility permission required`

Success remains for three seconds; failure and permission messages remain for
six seconds. Progress messages stay until replaced by the next operation state.

## Threading

Bluetooth enumeration, inquiry, pairing, connection polling, Accessibility trust
checks, System Settings AX traversal, and Forget postcondition polling execute
on background queues. AppKit status-item, menu, alert, and popup mutations are
confined to the main actor. Service events cross back to the main actor only for
popup updates.

## Logging

The app writes timestamped append-only diagnostics to:

```text
~/Library/Logs/MagicMouseSwitch/MagicMouseSwitch.log
```

Logs include application lifecycle, shortcut registration, status refreshes,
operation start/end, selected device, toggle branch, System Settings acquisition
and retries, inquiry duration, pairing duration/result, every relevant pairing
callback, final Forget AX result, Forget postcondition, and failures. **Open
Logs** opens the containing directory.

## Single-instance behavior

At launch, the app checks for another running application with bundle identifier
`com.ranveerrai.MagicMouseSwitchMac`. A second instance activates the existing
instance and exits before creating another operational controller.

## Development bundle

Build and create the local app bundle from `macos`:

```sh
./scripts/package-magic-mouse-switch-app.zsh debug
```

The script uses ad-hoc signing by default for non-destructive UI validation. For
a durable Accessibility identity during hardware testing, use an installed Apple
Development identity:

```sh
MAGIC_MOUSE_SWITCH_SIGNING_IDENTITY='Apple Development: Your Name (TEAMID)' \
  ./scripts/package-magic-mouse-switch-app.zsh debug
```

The resulting development bundle is:

```text
/Users/ranveerrai/Developer/MagicMouseSwitch/macos/.build/debug/MagicMouseSwitchMac.app
```

## Manual test procedure

1. Keep the built-in trackpad or another mouse available.
2. Package with a durable signing identity, add the app to Privacy & Security →
   Accessibility, enable it, and relaunch it.
3. Confirm the menu-bar icon is visible, there is no Dock icon, and the menu
   shows the current connected/paired state.
4. Confirm Refresh Status changes no device state.
5. With the mouse paired, choose Toggle or press Control-Shift-M once. Confirm
   the Forget popup sequence, the exact device disappears from My Devices, and
   logs record the authoritative postcondition.
6. Make the mouse discoverable. Choose Toggle or press the shortcut once.
   Confirm Searching → Pairing → Connected, then verify physical cursor movement,
   clicking, and scrolling.
7. During either operation, press the shortcut repeatedly and confirm the log
   records ignored repeats and no second operation begins.
8. Launch the app bundle again and confirm the second instance exits.

The current milestone's automated validation must stop after the initial
read-only status refresh. It must not choose Pair, Forget, or Toggle.

## Known limitations

Classic Bluetooth inquiry usually finds the pinned mouse in under one second,
but validated hardware testing observed one successful inquiry taking 12.149
seconds. The popup therefore remains in `Searching for Magic Mouse…` until the
bounded inquiry completes; this delay is expected and remains within the
30-second safety deadline.
