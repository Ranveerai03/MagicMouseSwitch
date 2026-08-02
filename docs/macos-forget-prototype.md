# macOS DeviceForget prototype

## Scope

`DeviceForget` is an OS-specific command-line prototype for the single validated
Apple Magic Mouse. It automates the observed System Settings path:

```text
Bluetooth → exact Magic Mouse row → Show Detail
          → Forget This Device… → Forget Device
```

It does not use a private Bluetooth API. The pairing-record change is performed
only by System Settings after the command verifies and invokes the final
Accessibility button.

This target must be tested only with a backup pointing device available. It has
no GUI, menu-bar integration, hotkey, pairing, inquiry, reconnect, or generalized
device-selection behavior.

## Invocation and confirmation

The command requires exactly:

```text
DeviceForget --address <bluetooth-address>
```

Before System Settings is opened, it prints the selected name, address, paired
state, connected state, and class. It then requires the exact case-sensitive
phrase:

```text
FORGET MAGIC MOUSE
```

The phrase is not trimmed, case-folded, or normalized. A mismatch exits non-zero
without starting UI automation.

## Bluetooth safety gates

Selection is based only on `IOBluetoothDevice.pairedDevices()` and reuses
`DeviceSelectionCore.ForgetSafety`. Exactly one record must satisfy all of:

1. Its address normalizes to the configured address. Normalization removes `-`
   and `:` separators, requires exactly 12 ASCII hexadecimal digits, and compares
   the lowercase result.
2. `isPaired()` is `true`.
3. Its name contains `Magic Mouse`, case-insensitively.
4. `classOfDevice` is exactly `0x002580`.
5. No second record satisfies every condition.

Connected state is displayed but is not an initial eligibility requirement. The
complete selected snapshot—including exact name, displayed address, paired,
connected, and class values—is frozen. Immediately after confirmation and before
each AX press, the command re-enumerates paired devices and requires the current
snapshot to equal the frozen snapshot. Any change aborts.

`AXIsProcessTrusted()` must also be `true`. Otherwise the command exits before
opening System Settings.

## Accessibility verification

The command opens only:

```text
x-apple.systempreferences:com.apple.BluetoothSettings
```

### System Settings launch and window acquisition

Before opening the URL, the command snapshots all running System Settings
process identifiers and every AX-readable window title. It inspects each window
hierarchy and records whether Bluetooth Settings was already open. An existing
System Settings process is foregrounded before navigation; no fixed process or
window index is assumed.

After the supported URL is opened, one overall 15-second acquisition deadline
covers bounded retries for all of these steps:

1. Re-enumerate live System Settings processes.
2. Create a new AX application element for each live process.
3. Re-enumerate that application's windows.
4. Read a new hierarchy for each window.
5. Identify the Bluetooth window from its `Bluetooth` title or the known
   Bluetooth device-row hierarchy containing the exact selected mouse name and
   a Bluetooth label or known device control.

The command never assumes window 1 is the Bluetooth window. Every retry creates
a new AX application element and new window hierarchies, so a reference obtained
while System Settings is starting cannot be reused after the UI changes.

If no readable window appears, or only a non-Bluetooth window is readable, the
command foregrounds System Settings and opens the same supported Bluetooth URL
one additional time. It then continues ordinary retries without performing a
second additional navigation attempt. Failure after the overall 15-second
deadline is non-destructive.

Launch/acquisition messages use ISO-8601 timestamps and report:

- the pre-launch process/window snapshot and whether Bluetooth was already open;
- each successful Bluetooth URL open;
- each System Settings PID found;
- each newly acquired AX application element;
- every successful window enumeration and its count;
- the PID whose Bluetooth window was found; and
- retry reasons, including AX error codes for unreadable windows.

Once acquired, the Bluetooth base page still has its existing bounded UI-state
wait. A pre-existing sheet is treated as an unexpected state and causes failure.
All later transition polling also recreates the AX application element and
Bluetooth window hierarchy on every poll.

### Device row

The hierarchy is read from scratch. It must contain exactly one `AXStaticText`
whose value equals the exact selected device name. Within that element's parent:

1. The next sibling must be a non-empty `AXStaticText` status.
2. The following sibling must be an `AXButton` described exactly as
   `Show Detail`.
3. The three-element local block must contain exactly one such Show Detail
   button.
4. The button must be explicitly enabled and advertise `AXPress`.

Only after those checks and another Bluetooth revalidation is `Show Detail`
pressed.

### Details sheet

After the transition, the complete hierarchy is polled and then discarded. A
fresh hierarchy is read after another Bluetooth revalidation. Exactly one
`AXSheet` must contain:

- exactly one element whose value equals the exact selected mouse name; and
- exactly one enabled `AXButton` whose description is exactly
  `Forget This Device…` and which advertises `AXPress`.

The validated live UI exposes the name as an `AXTextField` in this sheet. The
command matches its exact value rather than assuming a text role. Only the newly
resolved Forget button is pressed.

### Confirmation sheet

The command waits for a confirmation text that contains both:

- `Are you sure you want to forget`; and
- the exact selected device name.

It then revalidates Bluetooth and rereads the hierarchy. The unique confirmation
text must be inside an `AXSheet`. The deepest containing sheet is used because
the confirmation sheet is nested inside the details sheet. Its subtree must
contain exactly:

- one `AXButton` labelled/described `Cancel`; and
- one enabled `AXButton` labelled/described `Forget Device` that advertises
  `AXPress`.

The command never identifies the final button from position alone. Only after
every gate succeeds is the freshly resolved `Forget Device` button pressed.

No AX element from a previous UI transition is reused. Every actionable element
comes from a new hierarchy read performed after the preceding transition and
Bluetooth revalidation.

## AX result and postcondition handling

The validated inspection showed that an AX action can report an error even when
the UI transition occurs. Therefore DeviceForget never retries a press. It logs
a non-success immediate AX result and waits for the independently verified next
state:

- details sheet after Show Detail;
- exact-name confirmation after Forget This Device; or
- disappearance of the configured address from paired devices after the final
  Forget Device press.

If the expected postcondition does not appear, the command exits non-zero.

## Completion timeout

After the final press, the command polls
`IOBluetoothDevice.pairedDevices()` every 250 milliseconds for at most 20
seconds. Success requires that no returned paired record has the normalized
configured address.

A `nil` paired-device result is an error, not proof of successful removal. The
command prints exactly:

```text
Forget completed successfully.
```

only after the address has disappeared. If it remains present at the deadline,
the command exits non-zero and does not press any UI control again.

## Failure and recovery

All identity, hierarchy, uniqueness, enabled-state, action, and timeout failures
exit non-zero. Recovery depends on when the failure occurred:

- Before the final Forget Device press, no pairing change should have occurred.
  If System Settings remains on a confirmation, choose **Cancel** manually. If
  the details sheet remains open, choose **Done** manually.
- If the final press occurred but the command timed out or reported an AX error,
  do not run the command again immediately. Check System Settings and use a
  read-only paired-device enumeration to determine whether the address is still
  paired.
- If the address is absent, treat the mouse as forgotten even if the immediate
  AX result was non-zero. Re-pair manually if the removal was unintended.
- If the address remains paired, close any remaining System Settings sheet with
  Cancel or Done. The existing pairing should remain usable.
- Keep the Mac's built-in trackpad, another mouse, or keyboard navigation
  available throughout the hardware test.

The command does not implement rollback because recreating a pairing is a
separate state-changing workflow.

## Expected manual re-pair workflow

After a successful Forget:

1. Pair the Magic Mouse with the other computer using that computer's supported
   Bluetooth UI.
2. To return the mouse to macOS, disconnect or forget it on the other computer
   or disable Bluetooth there.
3. Power-cycle the Magic Mouse so it becomes discoverable.
4. Open macOS System Settings → Bluetooth and pair/connect the matching Magic
   Mouse manually.
5. Verify cursor input, not merely the displayed paired state.

For a rechargeable Magic Mouse, connecting it to the Mac with its USB cable and
turning it on is the supported fallback pairing procedure.

## Manual hardware-test command

The raw SwiftPM executable is ad-hoc signed. Its designated requirement is tied
to the current CDHash, so rebuilding invalidates its TCC Accessibility identity.
Do not authorize or execute that raw artifact for the hardware test.

Install an Apple Development code-signing identity, then create the stable signed
app wrapper from the `macos` directory:

```sh
DEVICE_FORGET_SIGNING_IDENTITY='Apple Development: Your Name (TEAMID)' ./scripts/package-device-forget-app.zsh debug
```

Remove any stale raw `DeviceForget` entries from Privacy & Security →
Accessibility, add this app, enable it, and fully restart Terminal:

```text
/Users/ranveerrai/Developer/MagicMouseSwitch/macos/.build/debug/DeviceForget.app
```

Then run its contained command-line executable:

```sh
/Users/ranveerrai/Developer/MagicMouseSwitch/macos/.build/debug/DeviceForget.app/Contents/MacOS/DeviceForget --address d0-c0-50-d5-10-77
```

Then type `FORGET MAGIC MOUSE` exactly when prompted. This milestone builds and
tests the executable but does not run that command.
