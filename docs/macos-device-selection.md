# macOS device selector architecture

## Purpose

`DeviceSelector` is a deterministic, read-only command-line target that identifies one already-paired Magic Mouse from an explicitly configured Bluetooth address. It does not connect, disconnect, pair, unpair, discover nearby devices, or automate macOS UI.

Build and invoke it from the repository root:

```sh
swift build --package-path macos -c release -Xswiftc -warnings-as-errors
macos/.build/release/DeviceSelector --address d0-c0-50-d5-10-77
```

The address is a required argument rather than a source-code constant. This keeps device configuration separate from executable logic and prevents silently acting on a developer-specific default.

## Components

- `DeviceSelector/main.swift` is the thin macOS adapter. It reads `IOBluetoothDevice.pairedDevices()` and maps cached properties into value records.
- `DeviceSelectionCore/BluetoothAddressNormalizer.swift` owns address validation and canonicalization.
- `DeviceSelectionCore/DeviceSelection.swift` contains the platform-independent name filter, exact-address selection algorithm, and typed failure cases.
- `DeviceSelectionCoreTests` validates the helpers without accessing Bluetooth hardware.

Only the executable target imports `IOBluetooth`. The selection core has no Bluetooth framework dependency, making its safety-critical matching behavior unit-testable with inert values.

## Matching algorithm

1. Require one `--address <value>` argument.
2. Validate and normalize the configured address.
3. Read the system's already-paired records with `IOBluetoothDevice.pairedDevices()`.
4. Retain every record whose cached name contains `Magic Mouse`, using a case-insensitive comparison.
5. Normalize each candidate address and compare it with the normalized configured address.
6. Succeed only when exactly one candidate has that address.

Having multiple paired Magic Mice is safe: the pinned address may select one of them. Having multiple records that both normalize to the pinned address is treated as ambiguous and fails closed.

## Address normalization

Normalization:

- trims leading and trailing whitespace;
- removes hyphens (`-`) and colons (`:`);
- requires exactly 12 remaining ASCII hexadecimal digits; and
- converts the result to lowercase.

For example, `D0-C0-50-D5-10-77`, `d0:c0:50:d5:10:77`, and `d0c050d51077` all normalize to `d0c050d51077`.

No other punctuation is discarded. An incomplete address, a nonhexadecimal character, or an unsupported separator makes the configured address invalid. Candidate records with invalid or unavailable addresses cannot match.

## Failure cases

The executable writes a clear diagnostic to standard error and exits nonzero when:

- arguments are missing or malformed (exit 64);
- the configured address is invalid;
- no paired device name contains `Magic Mouse`;
- Magic Mouse candidates exist but none has the configured address;
- more than one Magic Mouse record has the configured address; or
- an unexpected selection error occurs.

Selection failures use exit 2. Unexpected failures use exit 1. No fallback selects by name alone, array order, connection state, or the first result.

## Safety guarantees

`DeviceSelector` only invokes `IOBluetoothDevice.pairedDevices()` and reads these cached properties:

- `name`
- `addressString`
- `isPaired()`
- `isConnected()`
- `classOfDevice`

It contains no calls to `openConnection()`, `closeConnection()`, `IOBluetoothDeviceInquiry`, `IOBluetoothDevicePair`, CoreBluetooth scanning, Accessibility, Apple Events, or UI automation. It does not toggle Bluetooth or mutate pairing records.

The selector therefore cannot intentionally change Bluetooth state. Its output is merely the one value record that passed both independent gates: a Magic Mouse name and the exact pinned address. Any absence, mismatch, or ambiguity stops with an error.
