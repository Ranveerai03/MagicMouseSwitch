# macOS Bluetooth feasibility

Status: technical feasibility investigation only  
Date: 2026-07-30

## Executive conclusion

A macOS app can use Apple's **public `IOBluetooth` framework** to address one paired Bluetooth device and request that its baseband connection be closed or opened. That makes targeted disconnection of one paired Magic Mouse technically feasible without pairing, unpairing, private APIs, Accessibility, or System Settings automation.

Reconnection is promising but not yet proven end to end. `IOBluetoothDevice.openConnection()` publicly creates a baseband connection, but Apple does not document that this call guarantees that macOS will attach the HID profile and make a Magic Mouse usable. The Bluetooth link can also fail because the mouse is asleep, powered off, out of range, connected to another host, or no longer paired. A hardware test matrix is therefore a release gate. Until it passes, the accurate product conclusion is **conditionally feasible**, not “guaranteed reconnect.”

The recommended implementation is a small, native Swift macOS component using `IOBluetooth` for paired-device lookup and connection control. CoreBluetooth should not be used as the switching mechanism. Private APIs and UI automation should not be used.

## Public APIs

### IOBluetooth: appropriate for the switching operation

Apple describes [`IOBluetooth`](https://developer.apple.com/documentation/iobluetooth) as its public user-space Bluetooth interface. An [`IOBluetoothDevice`](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice) represents one remote device and can exist without a current baseband connection.

The relevant public operations are:

| Requirement | Public API | Meaning |
| --- | --- | --- |
| Enumerate paired devices | [`IOBluetoothDevice.pairedDevices()`](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/paireddevices%28%29?language=objc) | Returns the system's paired-device records. Apple notes that this list is system-wide, not per-user. |
| Identify one device | [`addressString`](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/addressstring) and `name` | Exposes the Bluetooth device address (BD_ADDR) and cached human-readable name. |
| Recreate a device reference | [`init(addressString:)`](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/init%28addressstring%3A%29?language=objc) | Resolves an `IOBluetoothDevice` for an exact BD_ADDR. |
| Check state | [`isPaired()`](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice) and [`isConnected()`](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/isconnected%28%29) | Reports pairing and baseband-connection state. |
| Disconnect | [`closeConnection()`](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/closeconnection%28%29?language=objc) | Synchronously requests closure of that device's baseband connection. |
| Reconnect | [`openConnection()`](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/openconnection%28%29?language=objc) | Synchronously requests creation of a baseband connection to that device. |

`IOBluetooth` is an older Objective-C macOS framework, but it remains publicly documented and its relevant properties and methods are present without deprecation annotations in the installed macOS SDK. Some old `get...` aliases are deprecated; use the properties and current method names shown above.

`closeConnection()` operates on the selected `IOBluetoothDevice`, so it need not disconnect the Bluetooth controller or unrelated devices. It closes the whole baseband link for the selected device, not one logical service on that device. That distinction is acceptable for a mouse, but the implementation must first resolve and validate the exact saved device.

### CoreBluetooth: not sufficient for Magic Mouse switching

[CoreBluetooth](https://developer.apple.com/documentation/corebluetooth) primarily presents peripherals discovered or known to an application's central manager and is designed around service communication. A `CBPeer` receives an app-specific [`identifier`](https://developer.apple.com/documentation/corebluetooth/cbpeer/identifier) UUID; CoreBluetooth does not expose the peer's Bluetooth MAC address.

CoreBluetooth can call [`connect(_:options:)`](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/connect%28_%3Aoptions%3A%29) and [`cancelPeripheralConnection(_:)`](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/1518952-cancelperipheralconnection). These manage the app's local CoreBluetooth relationship. Apple explicitly says that cancellation does **not** guarantee immediate physical-link disconnection because other applications may still use the peripheral. A Magic Mouse's HID connection is owned by the operating system, not by this app's `CBCentralManager`.

CoreBluetooth's BR/EDR support does not change that conclusion. Apple's [WWDC19 explanation](https://developer.apple.com/videos/play/wwdc2019/901/) describes GATT over BR/EDR and connection-event matching; it is not a general paired-HID connection manager.

CoreBluetooth is therefore not sufficient to reliably disconnect the system's Magic Mouse and should not be the switching backend. It could be useful only for a separate BLE/GATT feature in the future.

## Device identity and address stability

There are two different identifier models:

- `IOBluetoothDevice.addressString` exposes a six-byte BD_ADDR such as `aa:bb:cc:dd:ee:ff`.
- `CBPeer.identifier` is a UUID assigned by the local system when CoreBluetooth first encounters the peer. It is not the Bluetooth address and cannot be used to reconstruct an `IOBluetoothDevice`.

For a paired Magic Mouse represented through `IOBluetooth`, BD_ADDR is the best available public selector and should normally remain stable across application launches and ordinary reconnects. It must not be treated as a universal immutable identity: Bluetooth LE privacy can use private/random over-the-air addresses, pairing records can be removed and recreated, hardware can be replaced, and OS behavior may change.

Recommended identity policy:

1. On explicit user selection, save the canonical lowercase BD_ADDR.
2. Before every operation, resolve the address from `pairedDevices()` and require `isPaired() == true`.
3. Revalidate cached metadata: expected name contains `Magic Mouse`, and device class is consistent with a pointing device when available.
4. If validation is missing or ambiguous, fail closed and ask the user to select again. Never fall back to the first device with a matching name.

Names alone are unsafe because multiple mice can have the same name and users can rename devices. The CoreBluetooth UUID and IOBluetooth address should not be assumed to map to one another through any public API.

## Can one paired Magic Mouse be disconnected?

Yes, at the public baseband API level. The app can find exactly one paired `IOBluetoothDevice` by its saved BD_ADDR, verify its metadata and state, and invoke `closeConnection()` on only that object. It should never disable Bluetooth globally and should never enumerate by name and immediately act on the first match.

Important safety limitations:

- Closing the link immediately removes that mouse as an input device.
- A wrong saved target would disconnect the wrong device, so address pinning and fail-closed validation are mandatory.
- `closeConnection()` is synchronous and may block until success or failure; call it away from the main thread.
- “Disconnected” means the baseband link is down. The implementation should verify the state transition and report timeout/failure rather than claiming success from the request result alone.
- The OS or mouse may automatically reconnect after a deliberate close. That behavior must be measured on supported OS/device combinations.

## Can it be reconnected programmatically?

`IOBluetoothDevice.openConnection()` is a public programmatic baseband-connect request, so no private API or UI click is inherently required. It can target the exact saved paired device and does not itself pair the device.

However, successful baseband connection and a working mouse are not documented as equivalent. HID profile attachment is managed by macOS. The eventual implementation must distinguish:

1. the API request was accepted;
2. `isConnected()` became true; and
3. macOS restored the HID service and the mouse became usable.

The third condition needs hardware validation. Test at least every supported Magic Mouse generation, each supported macOS major version, sleep/wake, mouse power-cycle, out-of-range recovery, FileVault/login-window boundaries, and repeated switching between two computers. If public `openConnection()` cannot consistently restore HID, the product should report the limitation rather than silently adopt private APIs or System Settings automation.

## Private APIs and UI automation

### Private APIs

No private API is needed to enumerate paired devices or request a targeted baseband close/open. Private Bluetooth daemons, undocumented selectors, preference databases, and reverse-engineered command-line tools should not be used. They carry compatibility, code-signing, security, and App Review risks and could change in any macOS update.

If testing proves that public `openConnection()` does not restore the HID profile reliably, there is no documented public HID-specific “Connect” API to substitute. That result would be a product limitation, not justification to ship a private-API dependency.

### Accessibility or System Settings automation

Accessibility automation is not required for the recommended design. Driving System Settings would be fragile across macOS versions, localization, window state, and UI redesigns. It would also require the user to grant Accessibility control and could select the wrong same-named device unless extra safeguards were built.

Do not use AppleScript/System Events, Accessibility APIs, screen coordinates, image matching, or simulated clicks as the normal connection path. A user may always open System Settings manually as a recovery option.

## Permissions and distribution

The production `.app` should expect the following:

- Add `NSBluetoothAlwaysUsageDescription` to `Info.plist` with a specific explanation. Apple identifies this as the Bluetooth privacy usage-description key and documents Bluetooth as a protected resource ([usage-description documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription), [TCC reset reference](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos)). The user can deny or later revoke access in Privacy & Security.
- If App Sandbox is enabled, add `com.apple.security.device.bluetooth = true`. Apple documents this entitlement as permission for a sandboxed app to interact with Bluetooth devices ([entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.bluetooth), [sandbox configuration](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)).
- No Accessibility permission is needed when no UI automation is used.
- No administrator/root privilege, privileged helper, pairing entitlement, Input Monitoring permission, or Automation/Apple Events permission should be needed for the scoped Bluetooth backend.

Entitlements express intent but do not replace the user's privacy consent. Exact prompting and sandbox behavior for `IOBluetooth` must be verified using a signed `.app` on every minimum supported macOS version before choosing Mac App Store distribution. Direct notarized distribution is a lower-uncertainty initial path, but it does not remove TCC requirements.

The command-line enumerator in this repository has no app bundle or `Info.plist`. It is suitable for compile-time/API inspection and local developer diagnostics, not as proof of the production permission experience.

## Recommended architecture

Use a native Swift macOS process with a narrow Bluetooth service boundary:

```text
User-selected target record
  -> canonical BD_ADDR + cached metadata
  -> IOBluetoothDevice.pairedDevices()
  -> exact address match and safety validation
  -> serial operation coordinator
       -> disconnect: closeConnection() + bounded state verification
       -> reconnect: openConnection() + bounded baseband/HID verification
  -> structured result shown to the user
```

Design constraints for the later implementation:

- Keep device selection separate from connection actions. Selection is read-only and explicit.
- Serialize operations so connect and disconnect cannot race.
- Require an exact address match plus paired state and Magic Mouse metadata before any mutating call.
- Never pair, unpair, remove a pairing record, toggle the Bluetooth controller, or act on an ambiguous name.
- Use bounded retries with cancellation and clear failure reporting; do not loop indefinitely.
- Keep a manual recovery path visible, especially because disconnecting a pointing device can strand the user.
- Record API return codes and state transitions without logging full Bluetooth addresses by default; redact them in normal logs.
- Put all `IOBluetooth` calls behind a protocol so hardware integration tests and future framework changes do not leak through the application.

## API decision

| API/technique | Decision | Reason |
| --- | --- | --- |
| `IOBluetoothDevice.pairedDevices`, address, pairing and state APIs | **Use** | Public, system paired-device view with a targetable BD_ADDR. |
| `IOBluetoothDevice.closeConnection` | **Use after hardware safety tests** | Public targeted baseband disconnect. |
| `IOBluetoothDevice.openConnection` | **Use only after HID restoration tests pass** | Public targeted baseband connect; usable-HID restoration is not guaranteed by its documentation. |
| CoreBluetooth for switching | **Do not use** | Controls the app's peripheral session and cannot guarantee physical disconnection of the OS-owned HID link. |
| `IOBluetoothDeviceInquiry` | **Do not use for normal operation** | An active nearby-device inquiry is unnecessary when the target must already be paired. |
| `IOBluetoothDevicePair` / `IOBluetoothUI` | **Do not use** | Pairing is outside scope and increases risk. |
| Private Bluetooth APIs or undocumented tools | **Do not use** | Unstable and unsuitable for a supportable, reviewable application. |
| Accessibility/System Settings automation | **Do not use** | Unnecessary, permission-heavy, fragile, and difficult to make target-safe. |

## Prototype scope and next feasibility gate

The included Swift enumerator performs only `IOBluetoothDevice.pairedDevices()` and reads cached properties. It does not perform an inquiry, connect, disconnect, pair, unpair, open System Settings, or create UI.

It proves that the current Swift toolchain can compile against the public paired-device and identifier APIs. It deliberately does **not** prove disconnect/reconnect behavior. The next authorized phase should build a separately reviewed, explicit-confirmation hardware harness and test it with a backup input device attached; that phase is not part of this investigation.

## Hardware enumeration results

Test date: 2026-07-30

The unchanged read-only enumerator compiled successfully with `swiftc -warnings-as-errors` and the public `IOBluetooth` framework. The resulting binary was executed exactly once.

Enumeration did not complete. The process produced no standard output or standard error for approximately 90 seconds and did not exit. Because the program's first print occurs immediately after `IOBluetoothDevice.pairedDevices()` returns, the observed block occurred during that public paired-device enumeration call. The process was then interrupted with `SIGINT` and exited with status 130.

macOS returned no permission message or framework error to the command-line process, so the exact underlying cause cannot be established from this run. No alternate Bluetooth API, active scan, permission workaround, or UI automation was attempted.

Consequently, this run exposed no paired-device records and identified no devices whose name contains `Magic Mouse`. There are no observed names, Bluetooth addresses, paired states, connected states, or device classes to report, and address stability cannot yet be assessed from hardware output. This is a blocked enumeration result, not evidence that no Magic Mouse is paired.
