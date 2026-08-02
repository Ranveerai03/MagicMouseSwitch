# macOS DevicePair prototype

## Scope

`DevicePair` is a guarded command-line prototype that uses the public
`IOBluetoothDeviceInquiry` and `IOBluetoothDevicePair` APIs to discover and pair
one pinned, currently unpaired Apple Magic Mouse. It does not automate System
Settings and does not use Accessibility, AppleScript, private Bluetooth APIs,
global hotkeys, launch-at-login behavior, or menu-bar UI.

The configured hardware identity for the manual test is:

```text
Name: Ranveer's Magic Mouse
Address: d0-c0-50-d5-10-77
Device Class: 0x002580
```

The implementation intentionally applies the requirement that the name contain
`Magic Mouse` case-insensitively. The Bluetooth address and device class are the
strict identity gates; a matching name alone is never enough.

## Invocation and confirmation

The command accepts exactly:

```text
DevicePair --address <bluetooth-address>
```

The address is normalized by removing `:` and `-`, requiring exactly 12 ASCII
hexadecimal digits, and lowercasing the result. Before prompting or starting an
inquiry, the command checks `IOBluetoothDevice.pairedDevices()`. If any paired
record has the normalized pinned address, it exits successfully without inquiry
or pairing.

Otherwise, the command requires this exact case-sensitive phrase:

```text
PAIR MAGIC MOUSE
```

The phrase is not trimmed, case-folded, or otherwise normalized.

## Inquiry flow

After confirmation, the command creates one `IOBluetoothDeviceInquiry`, sets its
inquiry length to 30 seconds, and disables automatic remote-name updates so name
requests cannot extend the bounded inquiry. A wall-clock deadline also stops the
inquiry at 30 seconds in case the system throttles it.

Each discovery callback first normalizes the device address. Non-pinned devices
are ignored without logging or retaining their identities. When the pinned
address is found, it is retained and `stop()` is called immediately. The
completion and stop result codes are logged and must indicate success.

After the inquiry has stopped, exactly one retained device must satisfy all of:

1. Normalized address equals the configured address.
2. Name contains `Magic Mouse`, case-insensitively.
3. `classOfDevice` equals `0x002580`.
4. `isPaired()` is `false`.
5. No second retained device has the pinned address.

The command then prints Name, Address, Paired, Connected, and Device Class.

## Final pre-pair validation

Immediately before pairing, the command rereads the discovered object's address,
name, class, and paired state and reruns every identity check. It separately
re-enumerates `pairedDevices()` and requires zero records at the pinned address.
Any change aborts before the sole pairing start call.

## Pairing delegate behavior

The command creates one `IOBluetoothDevicePair` for the validated discovered
object and installs a dedicated delegate. It calls `start()` exactly once. The
delegate logs all public pairing progress and result callbacks:

- pairing started;
- baseband connecting;
- baseband connected;
- PIN code request;
- user-confirmation request and its numeric value;
- passkey notification and its passkey value;
- simple-pairing completion status; and
- final pairing completion result code.

The prototype does not contain or invent a PIN and never calls `replyPINCode`.
On a PIN request it reports the callback and stops the pairing attempt. No
automatic Apple-mouse PIN behavior is implemented because this milestone does
not rely on documented device-specific PIN guidance.

Numeric-confirmation and passkey callbacks are also unexpected for this mouse.
The delegate logs their exact values, does not call `replyUserConfirmation`, and
stops the pairing attempt. These callback decisions are pure logic covered by
unit tests.

## Completion and timeout handling

The inquiry has a 30-second maximum. No match, a non-success completion code, or
failure to stop after finding the pinned address is fatal.

Pairing has a separate 60-second wall-clock deadline. If no final pairing
callback arrives, the pairing object is stopped and the command exits non-zero.
An interactive PIN, numeric-confirmation, or passkey callback also stops the
attempt and exits non-zero. The command prints the pairing start code, pairing
duration, and final pairing result code when one is delivered.

After a successful pairing result, `pairedDevices()` must contain exactly one
record at the pinned address. That record must be paired, have a name containing
`Magic Mouse`, and have class `0x002580`. The command then polls fresh paired
records for up to 15 seconds for `connected == true`. It prints final paired and
connected states and fails if the connection deadline expires.

## Failure modes and recovery

The command exits non-zero for invalid arguments or addresses, incorrect
confirmation, inquiry start/completion/timeout failures, no pinned discovery,
duplicate pinned records, identity or state mismatches, pairing start/final
errors, unexpected authentication callbacks, pairing timeout, post-pair
verification failure, or connection timeout.

The command never forgets or unpairs a device, never calls `closeConnection()`,
and never interacts with a non-pinned device. If it stops on an authentication
callback, note the exact logged callback and status/value before trying another
workflow. If pairing succeeds but connection times out, inspect Bluetooth in
System Settings without rerunning immediately; the pairing record may already
exist, and a rerun will intentionally exit successfully before inquiry.

Keep the Mac's built-in trackpad, another mouse, or keyboard navigation
available during the hardware test.

## Manual hardware-test procedure

This implementation milestone builds and tests `DevicePair` but stops before
executing it. For the later guarded hardware test:

1. Confirm `Ranveer's Magic Mouse` remains absent from My Devices and visible
   under Nearby Devices in System Settings → Bluetooth.
2. Ensure another computer is not connected to the mouse. Power-cycle the mouse
   if needed so it is discoverable.
3. Keep the built-in trackpad or another pointing device available.
4. From the repository's `macos` directory, build Debug if the validated binary
   is not already present.
5. Run exactly:

   ```sh
   /Users/ranveerrai/Developer/MagicMouseSwitch/macos/.build/debug/DevicePair --address d0-c0-50-d5-10-77
   ```

6. Type `PAIR MAGIC MOUSE` exactly when prompted.
7. Preserve the full terminal output, including inquiry duration, pairing
   callbacks, pairing duration/result, and final paired/connected states.

## Verifying cursor movement

A successful API result and `connected == true` are necessary but not sufficient
for the hardware test. After the command reports success:

1. Move only the Magic Mouse while keeping the trackpad and backup mouse still.
2. Confirm the pointer moves continuously across the display.
3. Confirm a physical click is received by opening or focusing a harmless UI
   element.
4. Confirm scrolling works on the mouse surface.
5. In System Settings → Bluetooth, confirm `Ranveer's Magic Mouse` appears once
   under My Devices as connected.

If the pairing record exists but cursor input does not work, record that as a
hardware-test failure and do not forget the device with this prototype.
