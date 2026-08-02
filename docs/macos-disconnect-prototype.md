# macOS guarded disconnect prototype

## Scope

`DeviceDisconnect` is a deliberately narrow command-line prototype for disconnecting one already-paired Magic Mouse. It does not implement reconnection, pairing, unpairing, discovery scans, UI automation, Accessibility, a GUI, menu-bar behavior, or launch at login.

The executable is built during development but must not be run as part of an automated test. Disconnecting the mouse is an explicit manual hardware test with a backup input device available.

## Safety gates

The executable requires exactly one argument:

```text
--address <bluetooth-address>
```

Before showing a device, it reads only `IOBluetoothDevice.pairedDevices()` and requires exactly one record to satisfy every condition:

1. The record came from the system paired-device list.
2. Its address normalizes to the configured address.
3. Its name contains `Magic Mouse`, case-insensitively.
4. `isPaired()` is true.
5. `classOfDevice` is exactly `0x002580`, the pointing-device class observed during read-only enumeration.

Address normalization is provided by `DeviceSelectionCore`: trim only leading/trailing whitespace from the configured value, remove `-` and `:`, require 12 ASCII hexadecimal digits, and compare the lowercase canonical forms. Device selection fails closed if no record or multiple records pass all gates.

The selected name, address, paired state, connected state, and class are printed before any state-changing call. If the device is already disconnected, the program reports that fact, exits successfully, and never calls `closeConnection()`.

## Exact confirmation

A connected device requires this exact confirmation phrase:

```text
DISCONNECT MAGIC MOUSE
```

The terminal line delimiter produced by pressing Return is removed by `readLine`, but the entered text itself is not trimmed, normalized, or case-folded. Leading or trailing spaces, different capitalization, repeated spaces, or any other difference fail confirmation and exit nonzero.

After successful confirmation, the program enumerates the paired records again and repeats the complete address, name, paired-state, class, and uniqueness checks. Only the `IOBluetoothDevice` from this fresh validation can reach the disconnect call. If it has become disconnected, the program exits successfully without calling `closeConnection()`.

## Disconnect and result handling

The source contains exactly one `closeConnection()` call site, and a single execution can reach it at most once. There is no retry of the state-changing call.

The program captures and prints:

- the immediate `IOReturn` from `closeConnection()`;
- elapsed time from immediately before the call through bounded state polling;
- `isConnected()` immediately after the call returns; and
- `isConnected()` after bounded polling.

Any `IOReturn` other than `kIOReturnSuccess` causes a nonzero exit even if the observed connection state later becomes false.

## Timeout behavior

If the immediate state is still connected, the program polls `isConnected()` every 250 milliseconds. It performs at most 40 sleeps and subsequent checks, giving a polling window of no more than 10 seconds. It stops early as soon as the state becomes disconnected.

Remaining connected after the polling window is a failure and produces a nonzero exit. The synchronous `closeConnection()` call itself is controlled by `IOBluetooth` and is not included in the 10-second polling limit; its time is included in the printed elapsed duration.

## Failure modes

The executable exits nonzero for:

- missing or malformed command arguments;
- an invalid configured Bluetooth address;
- no device passing all five safety gates;
- more than one device passing all five safety gates;
- incorrect or missing confirmation;
- failure of the repeated final safety check;
- a non-success `closeConnection()` return code; or
- the selected mouse remaining connected after bounded polling.

It never falls back to a name-only match, the first paired device, a different device class, or an unpaired record.

## Manual hardware test procedure

Do not perform this test without a working backup pointing device or another reliable way to control macOS after the Magic Mouse disconnects.

1. Connect a USB mouse or trackpad and verify it controls the pointer.
2. Ensure the Magic Mouse is charged, powered on, paired, and currently connected.
3. Open macOS System Settings > Bluetooth manually and leave it available for recovery. Do not automate it.
4. Build and run all unit tests first.
5. Build the release executable with warnings treated as errors.
6. Run the exact manual command reported with this milestone.
7. Verify the printed name, address, paired state, connected state, and class before entering anything.
8. To proceed, type `DISCONNECT MAGIC MOUSE` exactly and press Return. Type anything else to abort safely.
9. Record the return code, elapsed time, immediate state, and final polled state printed by the prototype.

## Rollback procedure

If the Magic Mouse does not reconnect on its own, use the backup input device to open macOS System Settings > Bluetooth, find the same Magic Mouse, and choose **Connect** manually. Power-cycle the mouse if macOS instructs you to do so. Do not remove or recreate the pairing as part of this prototype test.

If no backup input device is available, do not start the disconnect test.
