# macOS guarded reconnect prototype

## Scope

`DeviceReconnect` is a guarded command-line prototype that requests a baseband connection to exactly one already-paired Magic Mouse through the public `IOBluetoothDevice.openConnection()` API. It does not implement a GUI, menu-bar behavior, launch at login, pairing, unpairing, scanning, inquiry, UI automation, or Accessibility.

Building and unit testing the target does not execute it. The first reconnect attempt is reserved for a separately authorized manual hardware test.

## Safety gates

The executable requires exactly:

```text
--address <bluetooth-address>
```

Before displaying a selection, the executable reads `IOBluetoothDevice.pairedDevices()` and requires exactly one record to satisfy every gate:

1. The record came from the system paired-device list.
2. Its normalized Bluetooth address exactly matches `--address`.
3. Its name contains `Magic Mouse`, case-insensitively.
4. `isPaired()` is true.
5. `classOfDevice` is exactly `0x002580`.

The neutral `GuardedMagicMouseSelection` helper in `DeviceSelectionCore` implements these gates for both disconnect and reconnect. It uses the existing address normalizer and Magic Mouse name matcher. No first-result or name-only fallback exists, and zero or multiple fully eligible records fail closed.

The command prints the selected name, address, paired state, connected state, and device class before any state-changing call. If the selected mouse is already connected, it reports that condition, exits successfully, and does not call `openConnection()`.

## Exact confirmation

A disconnected device requires this exact phrase:

```text
RECONNECT MAGIC MOUSE
```

Comparison is case-sensitive. `readLine` removes only the terminal line delimiter produced by pressing Return; the entered phrase is not trimmed, normalized, or case-folded. Extra spaces, missing spaces, or different capitalization fail confirmation and exit nonzero.

After successful confirmation, the command re-enumerates `pairedDevices()` and repeats all five gates and the uniqueness requirement against the configured address. Only the fresh `IOBluetoothDevice` from that second validation can reach the connection call. If it became connected in the meantime, the command exits successfully without calling `openConnection()`.

## Connection result handling

There is exactly one `openConnection()` call site. One process execution can reach it at most once; the command never retries the state-changing call.

The command captures and prints:

- the immediate `IOReturn` from `openConnection()`;
- elapsed time from immediately before the call through bounded polling;
- `isConnected()` immediately after `openConnection()` returns; and
- `isConnected()` after bounded polling.

Any return value other than `kIOReturnSuccess` is a failure, even if the observed connection state later becomes true. A successful baseband state is necessary but does not by itself prove that macOS restored functional HID cursor input.

## Timeout behavior

When the immediate state remains disconnected, the command polls `isConnected()` every 250 milliseconds. It performs at most 60 sleeps and subsequent checks, for a polling window no longer than 15 seconds. Polling stops early as soon as the state becomes connected.

If the device remains disconnected at the end of the bounded window, the command exits nonzero. `openConnection()` is synchronous and its internal duration is controlled by `IOBluetooth`; that call's duration is included in the printed elapsed time but is separate from the 15-second polling bound.

## Failure modes

The command exits nonzero for:

- missing or malformed arguments;
- an invalid configured Bluetooth address;
- zero fully eligible devices;
- multiple fully eligible records;
- missing or incorrect confirmation;
- failure of the repeated final safety check;
- a non-success `openConnection()` return code; or
- the device remaining disconnected after bounded polling.

It does not call `closeConnection()`, pair or unpair, perform inquiry or scanning, automate System Settings, use Accessibility, or act on any address other than the exact configured address.

## Manual hardware test procedure

1. Keep a working USB mouse or trackpad available throughout the test.
2. Confirm in macOS System Settings > Bluetooth that the target Magic Mouse is paired but disconnected.
3. Keep System Settings > Bluetooth open for manual fallback, without automating it.
4. Build debug and release configurations with warnings treated as errors and run all unit tests.
5. Run the exact command reported for this milestone.
6. Verify the printed name, address, paired state, connected state, and class before proceeding.
7. Type `RECONNECT MAGIC MOUSE` exactly and press Return. Any other input safely aborts.
8. Record the return code, elapsed time, immediate state, and final polled state.

## Verifying functional cursor input

An `isConnected()` result of true proves only the baseband state reported by `IOBluetooth`. After the command reports success:

1. Move the Magic Mouse without touching the backup pointing device.
2. Visually confirm that the onscreen pointer moves in direct response.
3. Click a harmless, non-destructive control and confirm the click is received.
4. Record separately whether baseband connection and functional cursor input each succeeded.

The prototype does not synthesize, capture, or monitor input, so cursor verification is intentionally manual and requires no Accessibility or Input Monitoring permission.

## Fallback procedure

If the command fails or reports connected state without restored cursor input, use the backup input device to open macOS System Settings > Bluetooth. Find the same Magic Mouse and choose **Connect** manually. Power-cycle the mouse if macOS requests it. Do not remove and recreate the pairing as part of this prototype test.

If no backup input device is available, do not perform the reconnect test.
