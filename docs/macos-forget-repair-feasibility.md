# macOS forget and re-pair feasibility

Status: research only  
Date: 2026-07-30  
Host inspected: macOS 27.0 (build 26A5388g)  
SDK inspected: macOS 27.0 at `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`

## Executive conclusion

The exact workflow is **not fully available through documented public APIs**:

- Public `IOBluetooth` APIs can enumerate paired devices, discover in-range discoverable devices, and initiate pairing.
- No documented `IOBluetoothDevice`, public C, CoreBluetooth, or `IOBluetoothUI` API removes a system Bluetooth pairing record.
- `removeFromFavorites()` only removes a per-user favourite marker. It is not equivalent to **Forget This Device**.
- No supported system command-line interface for removing one pairing record was found.
- The supported user-facing way to forget a Magic Mouse is System Settings. Automating that operation would require Accessibility/UI automation and would inherit significant safety and compatibility risks.
- After the pairing has been removed, `IOBluetoothDeviceInquiry` plus `IOBluetoothDevicePair` provide a plausible public re-discovery and re-pair path. This path still requires a guarded hardware test with the Magic Mouse in discoverable mode.

Therefore, a completely programmatic, public-API implementation matching Windows is not currently feasible. The safest supported architecture is **manual Forget in System Settings, followed by public-API inquiry and pairing**. If one-click forgetting is a hard requirement, guarded System Settings UI automation is the only non-private route identified, and it should be treated as a fragile compatibility layer rather than a Bluetooth API.

No Bluetooth connection, inquiry, pairing, unpairing, or UI action was performed during this investigation.

## Documented public APIs

### IOBluetoothDevice

Apple documents [`IOBluetoothDevice`](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice) as a representation of one remote Bluetooth device. The installed `objc/IOBluetoothDevice.h` exposes these relevant symbols:

```objc
+ (instancetype)deviceWithAddressString:(NSString *)address;
@property (readonly) NSString *addressString;
@property (readonly, copy) NSString *name;
@property (readonly) BluetoothClassOfDevice classOfDevice;
+ (NSArray *)pairedDevices;
- (BOOL)isPaired;
+ (NSArray *)favoriteDevices;
- (BOOL)isFavorite;
- (IOReturn)addToFavorites;
- (IOReturn)removeFromFavorites;
```

There is no `unpair`, `forget`, `removePairing`, `deleteLinkKey`, or equivalent public method in the class header.

[`removeFromFavorites()`](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/removefromfavorites%28%29) is explicitly documented as removing the target from the **user's favourite devices list**. Pairing records are system-wide according to the `pairedDevices()` header documentation. These are separate stores and operations; removing a favourite does not remove link keys or make `isPaired()` false.

`requestAuthentication()` can initiate authentication and link-key generation for an existing baseband connection. It creates or uses pairing material; it does not remove pairing material.

Conclusion: `IOBluetoothDevice` can identify and inspect the pinned mouse, but cannot publicly forget it.

### IOBluetoothDeviceInquiry

Apple documents [`IOBluetoothDeviceInquiry`](https://developer.apple.com/documentation/iobluetooth/iobluetoothdeviceinquiry) as an in-range device search that can optionally retrieve names. The installed `objc/IOBluetoothDeviceInquiry.h` exposes:

```objc
+ (instancetype)inquiryWithDelegate:(id)delegate;
- (instancetype)initWithDelegate:(id)delegate;
- (IOReturn)start;
- (IOReturn)stop;
@property(assign) uint8_t inquiryLength;
@property(assign) IOBluetoothDeviceSearchTypes searchType;
@property(assign) BOOL updateNewDeviceNames;
- (NSArray *)foundDevices;
- (void)clearFoundDevices;
- (void)setSearchCriteria:(BluetoothServiceClassMajor)serviceClass
          majorDeviceClass:(BluetoothDeviceClassMajor)majorClass
          minorDeviceClass:(BluetoothDeviceClassMinor)minorClass;
```

Its delegate protocol exposes:

```objc
- deviceInquiryStarted:;
- deviceInquiryDeviceFound:device:;
- deviceInquiryUpdatingDeviceNamesStarted:devicesRemaining:;
- deviceInquiryDeviceNameUpdated:device:devicesRemaining:;
- deviceInquiryComplete:error:aborted:;
```

The default search type is `kIOBluetoothDeviceSearchClassic`; `kIOBluetoothDeviceSearchLE` can also be selected. Inquiry is throttled when invoked repeatedly. Name updates can extend the operation beyond `inquiryLength`, and the header warns that making separate remote-name requests while an inquiry is active can deadlock the process.

An inquiry can rediscover the unpaired Magic Mouse only while the mouse is in range and discoverable. It does not force a device into discoverable mode and cannot find a mouse that is not responding to inquiry, including one actively connected to another host.

### IOBluetoothDevicePair

Apple documents [`IOBluetoothDevicePair`](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevicepair) as an application-controlled pairing attempt. The installed `objc/IOBluetoothDevicePair.h` exposes:

```objc
+ (instancetype)pairWithDevice:(IOBluetoothDevice *)device;
- (IOReturn)start;
- (void)stop;
- (IOBluetoothDevice *)device;
- (void)setDevice:(IOBluetoothDevice *)device;
- (void)replyPINCode:(ByteCount)size PINCode:(BluetoothPINCode *)PINCode;
- (void)replyUserConfirmation:(BOOL)reply;
```

The delegate protocol exposes the exact progress and interaction callbacks:

```objc
- devicePairingStarted:;
- devicePairingConnecting:;
- devicePairingConnected:;
- devicePairingPINCodeRequest:;
- devicePairingUserConfirmationRequest:numericValue:;
- devicePairingUserPasskeyNotification:passkey:;
- deviceSimplePairingComplete:status:;
- devicePairingFinished:error:;
```

`start()` begins a pairing attempt for the supplied `IOBluetoothDevice`. The class does not require that the object came directly from the current inquiry; an object can also be recreated from the pinned address. In practice, pairing still requires the physical device to be reachable and accepting pairing.

For a Magic Mouse, Secure Simple Pairing is expected to use a no-keyboard/no-display or “Just Works” path, but Apple does not document the exact callback sequence for each Magic Mouse generation. The implementation must handle every delegate callback and must not assume that no confirmation will be requested. If `devicePairingUserConfirmationRequest` occurs, `replyUserConfirmation(_:)` is required before the Bluetooth timeout. PIN and passkey callbacks also need explicit safe handling even if hardware testing shows they are normally absent.

Calling `IOBluetoothDevicePair` for a device that is already paired is not a public way to refresh or replace its existing pairing. The intended re-pair use is after the system record has been forgotten and the device has been rediscovered or recreated by its still-valid address.

### IOBluetoothUI

The public `IOBluetoothUI.framework` contains `IOBluetoothPairingController` and `IOBluetoothDeviceSelectorController`. They present Apple-provided discovery/pairing windows and can initiate pairing. They expose no Forget or unpair operation. They are a possible fallback for re-pair user experience, not a solution for removing the existing pairing record.

## Public C headers and exact findings

### Bluetooth.h

`Bluetooth.h` defines protocol types, HCI command identifiers, structures, flags, and error codes. It includes:

```c
kBluetoothHCICommandDeleteStoredLinkKey = 0x0012
typedef uint8_t BluetoothHCIDeleteStoredLinkKeyFlag;
kDeleteKeyForSpecifiedDeviceOnly = 0x00
kDeleteAllStoredLinkKeys = 0x01
```

These are Bluetooth HCI protocol constants, not a callable public macOS pairing-removal API. The header provides no supported function that submits `Delete Stored Link Key` while also updating macOS's host-side pairing databases and services. Issuing raw controller commands would not be equivalent to System Settings and could leave the controller, `bluetoothd`, HID services, and host pairing database inconsistent. It is not a recommended path.

### IOBluetoothUserLib.h

`IOBluetoothUserLib.h` describes itself as public, but states that its old C device-inquiry API has been removed and directs clients to the Objective-C equivalents. It retains search option and search attribute types:

```c
kSearchOptionsAlwaysStartInquiry
kSearchOptionsDiscardCachedResults
kIOBluetoothDeviceSearchClassic
kIOBluetoothDeviceSearchLE
IOBluetoothDeviceSearchAttributes
```

Its `IOBluetoothIgnoreHIDDevice()` and `IOBluetoothRemoveIgnoredHIDDevice()` functions only control whether macOS should ignore a connecting HID device. “Remove ignored” means stop ignoring; it does not remove a pairing. The SCO audio add/remove functions manage an audio driver and are unrelated to pairing.

No public C function for forgetting, deleting a pairing, or deleting a host link key is declared.

### IOBluetoothUtilities.h

`IOBluetoothUtilities.h` contains address conversion, data packing, file helpers, and HID device-count utilities, including:

```c
IOBluetoothNSStringToDeviceAddress
IOBluetoothNSStringFromDeviceAddress
IOBluetoothNSStringFromDeviceAddressColon
IOBluetoothNumberOfAvailableHIDDevices
IOBluetoothNumberOfPointingHIDDevices
IOBluetoothNumberOfKeyboardHIDDevices
IOBluetoothNumberOfTabletHIDDevices
```

It contains no inquiry, pairing, or pairing-removal function.

## Public but deprecated or removed APIs

The relevant Objective-C APIs `removeFromFavorites`, `IOBluetoothDeviceInquiry`, and `IOBluetoothDevicePair` are **not marked deprecated** in the installed macOS 27 SDK.

Deprecated or removed items found during inspection are not solutions:

- The old C inquiry API has been removed from `IOBluetoothUserLib.h`; the header directs developers to `IOBluetoothDeviceInquiry`.
- Old `IOBluetoothDevice` getter aliases such as `getName`, `getAddressString`, `getClassOfDevice`, and `getServices` are deprecated in favour of properties.
- `IOBluetoothRemoveSCOAudioDevice` is deprecated and only concerns a persistent SCO audio driver.
- Several legacy `IOBluetoothUI` service-browser methods and passkey-display helpers are deprecated. Current pairing controllers remain available, but still offer no Forget operation.

No deprecated public unpair API was found.

## System-shipped tools and supported mechanisms

The following shipped components were inspected without invoking Bluetooth operations:

| Component | Finding |
| --- | --- |
| `/usr/sbin/BlueTool` | Apple-signed internal controller/firmware/HCI test utility. It has no man page or supported per-device Forget interface. Its embedded help focuses on opening hardware, raw HCI, power, reset, firmware, and test modes. It is not an application integration API. |
| `/usr/sbin/bluetoothd` | System Bluetooth daemon, not a supported client CLI. Binary strings show internal pairing and delete-pairing implementation, but no documented command interface. It must not be launched or controlled by the app. |
| `/usr/sbin/system_profiler` | Can report Bluetooth state through `SPBluetoothDataType`; it cannot mutate pairing records. |
| Bluetooth Setup Assistant / Bluetooth UI services | System UI components for discovery and pairing. No documented command interface for forgetting a specific device was found. |
| `blueutil` | Not installed and not shipped by Apple on this host. Third-party tools are outside the supported-mechanism requirement and commonly depend on undocumented behavior. |

The system `IOBluetooth.framework` export list contains undocumented symbols such as `_IOBluetoothRemoveCachedValue`, while the Bluetooth daemon and private frameworks expose internal delete-pairing behavior. These are not declared in public headers and must be classified as private. A cache-removal symbol is also not evidence that it performs the complete supported Forget transaction.

## Undocumented and private mechanisms

The installed system contains private frameworks including `BluetoothManager.framework`, `MobileBluetooth.framework`, and `BluetoothServices.framework`. The installed System Settings Bluetooth extension contains an internal `deleteDevice:completion:` selector and logs a successful unpair result. This explains how Apple's UI can perform an operation absent from public `IOBluetooth`.

These mechanisms are undocumented, can change without compatibility notice, may require Apple-only entitlements or XPC privileges, and are unsuitable for executable code in this project. No private symbol was called, linked, or added to source.

Directly editing Bluetooth preference files or deleting stored link keys is also not supported. Pairing state spans the daemon, controller, HID services, and persistent databases; partial deletion risks stale or inconsistent state.

## System Settings UI automation

### Is it required?

It is required only if the application itself must initiate **Forget This Device** without private APIs. A user-performed manual Forget remains the most reliable supported option.

Apple's current Mac guidance describes the supported path as the device row in **My Devices**, followed by its Information/Show Detail control and **Forget This Device** ([Mac Bluetooth guide](https://support.apple.com/en-ca/guide/mac-help/blth1004/mac), [Magic Mouse setup guidance](https://support.apple.com/en-ie/119917)).

### Accessibility inspection results

A direct, read-only Accessibility inspection succeeded on this host after
`AXIsProcessTrusted()` returned `true`. The inspection used
`AXUIElementCopyAttributeValue` and `AXUIElementCopyActionNames` only. It did not
call `AXUIElementPerformAction`, set an AX attribute, click a control, or perform
a Bluetooth operation.

The relevant live hierarchy on the Bluetooth page was:

```text
AXWindow (identifier: Main, title: Bluetooth)
└─ AXGroup / AXHostingView
   └─ AXSplitGroup (identifier: Main, SidebarNavigationSplitView)
      ├─ sidebar AXScrollArea
      │  └─ AXOutline (identifier: com.apple.settings.sidebar.collectionView)
      │     └─ Bluetooth AXButton (identifier: com.apple.settings.bluetooth)
      └─ content AXGroup / AXHostingView
         └─ AXScrollArea
            ├─ AXHeading (description: My Devices)
            ├─ AXGroup (paired-device contents)
            │  ├─ AXStaticText (value: Ranveer’s Magic Mouse)
            │  ├─ AXStaticText (value: Connected - 32%)
            │  ├─ AXButton (description: Show Detail)
            │  ├─ AXStaticText (value: AULA-F75 3.0 KB )
            │  ├─ AXStaticText (value: Not Connected)
            │  ├─ AXButton (description: Show Detail)
            │  ├─ AXStaticText (value: Ranveer’s AirPods Max)
            │  ├─ AXStaticText (value: Not Connected)
            │  ├─ AXButton (description: Show Detail)
            │  ├─ AXStaticText (value: Ranveer’s AirPods Pro)
            │  ├─ AXStaticText (value: Not Connected)
            │  └─ AXButton (description: Show Detail)
            ├─ AXHeading (description: Nearby Devices)
            └─ AXGroup (nearby-device contents)
               ├─ AXStaticText (value: iHome iBT230)
               ├─ AXStaticText (value: Scosche BTFM4)
               └─ AXStaticText (value: [TV] Samsung 7 Series (55))
```

The paired-device list is exposed as one flat `AXGroup`, not as an `AXList`,
`AXTable`, or separate `AXRow` elements. The Magic Mouse is therefore represented
by three adjacent children: its exact name, its status, and the following
details button. Their observed attributes were:

| Element | Role | Label/value/description | Identifier | Advertised actions |
| --- | --- | --- | --- | --- |
| Device name | `AXStaticText` | Value `Ranveer’s Magic Mouse` | None exposed | `AXShowMenu` |
| Device status | `AXStaticText` | Value `Connected - 32%` | None exposed | `AXShowMenu` |
| Associated details control | `AXButton` | Description `Show Detail` | None exposed | `AXPress` |

The details control is associated with the Magic Mouse only by its position
immediately after that device's name and status. It has no device-specific label
or identifier and the live UI exposes no Bluetooth address. This makes exact
row-to-button targeting possible for the observed hierarchy, but less reliable
than an explicit per-device row and unsafe when duplicate names or structural
changes are present.

`Forget This Device` was **not** directly exposed in the Bluetooth page's live
AX tree. It is expected inside the details view, but opening that view was
prohibited, so its live role, identifier, label, and action remain unverified.
Likewise, no confirmation dialog was present or detectable before interaction;
the dialog is created only after the Forget action is invoked.

Static read-only inspection of the installed extension at
`/System/Library/ExtensionKit/Extensions/Bluetooth.appex` separately identified
the current English strings `Forget This Device…`, `Forget Device`, `Cancel`,
and `Are you sure you want to forget “%@”?`. Those strings are implementation
evidence, not live AX identifiers. The extension also contains a pointing-device
safeguard prompt, which may add another dialog when forgetting the only usable
pointing device.

### Guarded Forget UI flow inspection

A guarded live inspection opened the selected mouse's details sheet and the
Forget confirmation, then dismissed both without pressing the final destructive
button. Before the first UI action and again between phases,
`IOBluetoothDevice.pairedDevices()` was required to return exactly one device
whose normalized address was `d0c050d51077`, whose exact current name was
`Ranveer’s Magic Mouse`, whose name contained `Magic Mouse` case-insensitively,
whose class was `0x002580`, and whose paired and connected states were both
`true`.

#### Matching strategy and safety gates

The Bluetooth page was reread from scratch. Selection required exactly one
`AXStaticText` with value `Ranveer’s Magic Mouse`. In its flat device-group
parent, the next element had to be an `AXStaticText` whose value began with
`Connected`, and the element after that had to be the only `AXButton` described
as `Show Detail` in that three-element local block. The observed status was
`Connected - 32%`.

After opening details, the exact device name changed role: it was exposed as an
`AXTextField`, not an `AXStaticText`. A first fail-closed check stopped because it
assumed the name would remain static text. A separate read-only reread established
that the exact name was present, after which the continuation revalidated every
Bluetooth gate and the already-open details sheet before proceeding. Matching
must therefore use an exact AX value plus an expected enclosing structure, not
assume one text role across screens.

The details hierarchy was:

```text
AXWindow (identifier: Main, title: Bluetooth)
└─ AXSheet (actions: AXRaise)
   └─ AXGroup / AXHostingView
      ├─ AXScrollArea
      │  ├─ AXGroup
      │  │  ├─ AXStaticText (value: Name)
      │  │  └─ AXTextField (value: Ranveer’s Magic Mouse;
      │  │                  actions: AXShowMenu, AXConfirm)
      │  └─ AXGroup
      │     ├─ AXStaticText (value: Model Name)
      │     ├─ AXStaticText (value: Magic Mouse)
      │     ├─ AXStaticText (value: Version)
      │     ├─ AXStaticText (value: 3.1.4)
      │     └─ AXButton (description: Mouse Settings…; action: AXPress)
      ├─ AXButton (description: Forget This Device…; action: AXPress)
      ├─ AXButton (description: Disconnect; action: AXPress)
      └─ AXButton (description: Done; action: AXPress)
```

The details controls exposed no title or identifier. The exact device name and
the single `Forget This Device…` button were required to occur within the same
details hosting-group subtree. The `Disconnect` and `Mouse Settings…` controls
were observed but never invoked.

Pressing the uniquely verified `Forget This Device…` button created a nested
confirmation sheet:

```text
details AXSheet
└─ AXSheet (actions: AXRaise)
   ├─ AXStaticText
   │  identifier: _NS:74
   │  value: Are you sure you want to forget “Ranveer’s Magic Mouse”?
   │  actions: AXShowMenu
   ├─ AXStaticText
   │  identifier: _NS:58
   │  value: This device will not reconnect automatically. You will have to
   │         connect it again if you want to use it later.
   │  actions: AXShowMenu
   ├─ AXButton
   │  identifier: action-button-1
   │  description: Forget Device
   │  action: AXPress
   └─ AXButton
      identifier: action-button-2
      description: Cancel
      action: AXPress
```

No titles were exposed on those confirmation elements. The dialog gate required
one confirmation text containing the exact selected name, exactly one Cancel
button, and exactly one Forget Device button in the same nested sheet. The
`Forget Device` button was identified but **never pressed**.

#### Cancellation and postconditions

The first `AXPress` sent to the uniquely verified Cancel button returned AX error
`-25205`. A fresh read showed that the confirmation had nevertheless disappeared,
so Cancel was not retried. This mismatch between the immediate AX return and the
observed UI postcondition is an important reliability risk. The remaining details
sheet was tied to the exact-name `AXTextField`, verified to contain one
`Forget This Device…` button and one `Done` button, and closed using that unique
Done control. Final IOBluetooth validation confirmed that address
`d0-c0-50-d5-10-77` was still paired and connected.

Every AX action invoked during this inspection was:

| Sequence | Verified target | Action | Immediate result | Observed result |
| --- | --- | --- | --- | --- |
| 1 | Adjacent Show Detail button for `Ranveer’s Magic Mouse` | `AXPress` | `0` | Details sheet opened. |
| 2 | Unique `Forget This Device…` button in the exact-name details subtree | `AXPress` | `0` | Confirmation sheet opened. |
| 3 | Unique Cancel button in the exact-name confirmation sheet | `AXPress` | `-25205` | Confirmation sheet disappeared; action was not retried. |
| 4 | Unique Done button in the remaining exact-name details sheet | `AXPress` | `0` | Details sheet closed. |

System Settings was also navigated to its Bluetooth URL through `NSWorkspace`;
that navigation was not an AX action. No connection, disconnection, pairing,
unpairing, inquiry, scan, private API, or final Forget action was performed.

#### Controlled-prototype assessment

The complete non-destructive UI path can be identified on this tested macOS
build, so a tightly controlled, fail-closed prototype appears technically
possible. It is not robust enough to treat as a general Bluetooth API:

- the device-to-details relationship depends on positional adjacency in a flat
  group and the UI exposes no Bluetooth address;
- the selected name changes from `AXStaticText` on the list to `AXTextField` in
  details;
- labels, identifiers, hierarchy, localization, and safeguard dialogs can drift;
- the Cancel action returned an AX error even though its UI postcondition occurred;
  therefore both action results and independently observed postconditions must be
  handled conservatively; and
- an implementation must revalidate the pinned IOBluetooth device before every
  action, resolve fresh AX elements after each UI transition, require exact
  uniqueness at every level, and verify the final pairing state independently.

These constraints support an OS-version-specific experimental prototype with a
backup pointing device, but not a claim of reliable supported automation across
macOS releases.

### UI automation safety constraints

If UI automation is later authorized, it must:

1. Prevalidate the pinned address, name, paired state, and class through `IOBluetooth`.
2. Require a unique visible row with the exact cached name; abort if duplicate Magic Mouse names exist because the UI row may not expose BD_ADDR.
3. Use AX roles, labels, and actions—not coordinates, images, or timing-only clicks.
4. Require an exact destructive confirmation phrase in the app before opening the Forget flow.
5. Verify every dialog label and the selected device name before pressing a destructive control.
6. Handle the possible “last pointing device” safeguard and require a backup input device.
7. Verify the postcondition through `IOBluetoothDevice.pairedDevices()`: the pinned address must no longer be paired.
8. Fail closed on localization, layout, missing controls, additional dialogs, or OS-version drift.

Even with these constraints, System Settings automation is less reliable than a Bluetooth API and must be tested on every supported macOS release.

## Rediscovering the unpaired Magic Mouse

### Inquiry and identity

The observed mouse is a classic pointing device (`classOfDevice == 0x002580`) with BD_ADDR `d0-c0-50-d5-10-77`. `IOBluetoothDeviceInquiry` defaults to classic inquiry, so it is the appropriate public discovery mechanism to test.

The later implementation should preserve the pinned address before Forget, perform one bounded inquiry, and accept only a result satisfying all of:

- normalized address equals the pinned address;
- name contains `Magic Mouse` once name updating completes;
- class is exactly `0x002580`; and
- exactly one result satisfies all conditions.

Address should be the primary identity. The name may be absent in the initial found callback and become available only through the inquiry's name-update callbacks. Pairing must not fall back to name alone.

### Address stability after forgetting

For a classic device, BD_ADDR is the device identity used by inquiry; forgetting removes host pairing material rather than changing the accessory's hardware address. The address is therefore expected to remain stable for this Magic Mouse. Apple does not explicitly guarantee address persistence across every Magic Mouse generation, repair, or firmware behavior, so a hardware test must confirm that the rediscovered result still equals the saved address. Any mismatch must abort.

### Discoverable mode and power cycling

Inquiry only finds devices currently responding in discoverable mode. Apple states that an accessory must be turned on and discoverable to pair. For earlier Apple wireless mice, Apple specifically says a blinking LED indicates discovery; if the device is connected to another nearby Mac, forget it there, then turn it off and back on ([Apple setup instructions](https://support.apple.com/en-ie/119917)).

For the intended two-computer workflow:

- The other computer must disconnect or forget the mouse, or have Bluetooth disabled, before macOS attempts rediscovery.
- Power cycling should be treated as an expected user step because it is Apple's documented way to return earlier models to discovery and is often needed after changing hosts.
- A mouse actively connected to the other computer should not be expected to appear in macOS inquiry.
- Modern rechargeable Magic Mouse models have an officially supported fallback: connect the mouse to the Mac with its USB cable and turn it on; macOS pairs it automatically. That fallback is reliable but is not the desired wireless switching experience.

The exact discoverability behavior of this physical mouse after pairing with the other computer remains a required hardware test.

## Re-pairing behavior and expected user interaction

A public re-pair prototype can use the exact `IOBluetoothDevice` returned by inquiry or recreate it from the pinned address, then create `IOBluetoothDevicePair`, set its delegate, and call `start()` once after explicit user approval.

Expected application responsibilities:

- Keep the pairing object and delegate alive until `devicePairingFinished:error:`.
- Display progress for started, connecting, and connected callbacks.
- Treat `devicePairingFinished:error:` as the authoritative completion result and also verify that `pairedDevices()` contains the pinned address afterward.
- Handle PIN, passkey, and numeric-confirmation callbacks without assumptions.
- Never accept a confirmation for a device whose address, name, paired state transition, or class differs from the pinned target.
- Provide bounded timeout and cancellation through `stop()`.

A Magic Mouse has no display or keyboard for numeric comparison. It is likely to follow a Just Works flow, and the installed System Settings extension contains an internal automatic-accept path for `justWorks`, but that private implementation detail is not a public contract. Hardware testing must record the actual `IOBluetoothDevicePairDelegate` sequence and whether user confirmation is requested.

## Permissions and entitlements

For public inquiry and pairing:

- Include [`NSBluetoothAlwaysUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription). Apple states it is required when an app uses the Bluetooth interface.
- If App Sandbox is enabled, include [`com.apple.security.device.bluetooth = true`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.bluetooth).
- The user must grant Bluetooth access in Privacy & Security. No separate public “pairing entitlement” is documented.
- Administrator/root access should not be required.

For System Settings UI automation:

- Direct Accessibility control requires the user to grant Accessibility permission in Privacy & Security ([Apple guidance](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/26/mac/26)).
- If the implementation uses Apple Events/System Events, it also requires Automation consent and `NSAppleEventsUsageDescription` ([Apple Events usage key](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)).
- A direct AX implementation may avoid Apple Events but still requires Accessibility permission.
- Screen Recording and Input Monitoring are not required when the implementation reads AX metadata and invokes AX actions without screenshots or input capture.
- Sandboxing and Mac App Store review are significant risks for an app whose core function controls System Settings. Direct notarized distribution is the more realistic path if AX automation is ultimately selected.

## Reliability risks

- There is no public Forget API, so a fully automatic workflow depends on System Settings UI structure.
- The UI does not necessarily expose BD_ADDR, weakening exact-device proof when names are duplicated.
- Labels, roles, hierarchy, popovers, confirmation sheets, and extra pointing-device safeguards can change with macOS or localization.
- Accessibility and Automation permissions can be denied or revoked.
- Inquiry is throttled, name resolution is asynchronous, and discovery duration is not strictly bounded when name updates are enabled.
- The mouse may remain connected to the other host and therefore not be discoverable.
- Power cycling may be required.
- Address stability is expected for this classic mouse but must be verified after a real Forget.
- `IOBluetoothDevicePair` callback behavior for this Magic Mouse generation is not documented.
- Pairing success does not guarantee immediate HID cursor input; both paired state and functional cursor movement need separate verification.
- iCloud or Apple Account synchronization behavior can complicate some Apple accessories, although this Magic Mouse is expected to use a local classic pairing record.

## Recommended implementation path

### Recommended supported path

1. Keep the existing pinned-address selector and destructive confirmation safeguards.
2. Guide the user to manually choose **Forget This Device** in System Settings. Afterward, verify read-only that the pinned address has disappeared from `pairedDevices()`.
3. Let the user pair the mouse with the other computer.
4. When returning to macOS, instruct the user to release the mouse from the other host and power-cycle it.
5. Run one bounded `IOBluetoothDeviceInquiry`, resolve names after discovery, and require the pinned address, Magic Mouse name, class `0x002580`, and one exact match.
6. After exact user confirmation, use `IOBluetoothDevicePair` once and handle every delegate callback.
7. Verify the pinned address reappears in `pairedDevices()`, then manually verify cursor input.
8. Offer cable pairing or manual System Settings pairing as the fallback.

This path uses supported interfaces for every programmatic Bluetooth operation and keeps the unsupported gap as an explicit user action.

### If automatic Forget is mandatory

Use public Accessibility APIs to automate only the documented System Settings flow, with the safety constraints above. Do not use private Bluetooth frameworks, daemon XPC, raw HCI deletion, preference-file edits, or undocumented command-line tools.

Before implementation, a separate milestone should grant the necessary permissions and perform a read-only AX hierarchy capture on the Bluetooth page. The destructive flow should then be prototyped only with a backup pointing device and explicit confirmation. Its success criterion is not the UI click: it is the pinned address disappearing from `pairedDevices()`.

### Required next feasibility tests

No implementation should proceed until separately authorized tests establish:

1. Whether this physical Magic Mouse retains `d0-c0-50-d5-10-77` after Forget.
2. Whether it appears in classic `IOBluetoothDeviceInquiry` after the other computer releases it and it is power-cycled.
3. When its name becomes available during inquiry.
4. The exact `IOBluetoothDevicePairDelegate` callback sequence.
5. Whether pairing completes without a PIN or numeric-comparison interaction.
6. Whether the mouse becomes functional HID input after pairing.

## Feasibility decision

| Capability | Decision |
| --- | --- |
| Public programmatic Forget | **Not available** in inspected documented APIs. |
| Public rediscovery | **Available in principle** through `IOBluetoothDeviceInquiry`; hardware validation required. |
| Public re-pair | **Available in principle** through `IOBluetoothDevicePair`; callback and HID validation required. |
| Public Apple pairing UI | Available through `IOBluetoothUI`; does not solve Forget. |
| Supported system CLI for Forget | **None found.** |
| Private daemon/framework deletion | Exists internally but **must not be used**. |
| System Settings UI automation | Technically plausible and the only identified automatic non-private route, but permission-heavy and fragile. |
| Recommended first product path | Manual System Settings Forget plus guarded public inquiry and pairing. |
