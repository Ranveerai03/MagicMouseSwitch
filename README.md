# Magic Mouse Switch

The project is currently at the required Phase 1 feasibility gate. It targets .NET 8 on Windows 11 and uses `Windows.Devices.Enumeration` AssociationEndpoint objects.

The confirmed target is pinned to Bluetooth address `d0:c0:50:d5:10:77`. Address comparison strips separators and is case-insensitive through canonical normalization. A matching endpoint must also have a name containing `Magic Mouse`. No pairing or unpairing operation is allowed against any other address.

## Read-only endpoint check

```powershell
dotnet run --project .\MagicMouseSwitch.Cli -- dry-run
```

## Windows Settings pairing fallback

`DeviceInformationPairing.PairAsync()` returned `Failed` for this mouse while manual Windows Settings pairing succeeded. The supported pairing path is therefore UI Automation over the Windows Settings pairing dialog:

```powershell
dotnet run --project .\MagicMouseSwitch.Cli -- pair-ui
```

This uses AutomationElement patterns rather than screen coordinates or image matching. It validates the unpaired AssociationEndpoint's pinned address before selecting the one non-ambiguous visible Magic Mouse result.

Dialog opening uses an existing usable `Add a device` ApplicationFrameWindow when available. Otherwise it opens the Bluetooth Settings page and makes two bounded 8-second attempts to invoke `Add device`. Magic Mouse UI-row monitoring and the pinned-address `DeviceWatcher` run concurrently; selection occurs immediately after both safety conditions are ready. Successful and failed runs print an elapsed timing summary.

By default, `pair-ui` selects the single exact visible `Ranveer's Magic Mouse` row and then verifies the sole paired Magic Mouse AssociationEndpoint has the pinned address. A mismatched newly paired endpoint is immediately unpaired. To retain address verification before UI selection, use:

```powershell
dotnet run --project .\MagicMouseSwitch.Cli -- pair-ui --strict-address-before-click
```

To inspect the top-level Add a device dialog without selecting any device:

```powershell
dotnet run --project .\MagicMouseSwitch.Cli -- inspect-pairing-ui
```

To exercise `pair-ui` independently, first run the confirmation-gated removal command, power-cycle the mouse, and then run `pair-ui`:

```powershell
dotnet run --project .\MagicMouseSwitch.Cli -- unpair
dotnet run --project .\MagicMouseSwitch.Cli -- pair-ui
```

## Deliberate unpair-and-UI-pair feasibility test

This command prints the selected endpoint and requires the exact phrase `UNPAIR RANVEER MAGIC MOUSE` before it changes anything:

```powershell
dotnet run --project .\MagicMouseSwitch.Cli -- feasibility-test
```

The destructive test prints and flushes a prominent confirmation banner before reading input. After successful paired, connected, and cursor checks, it closes the pairing dialog and closes Settings only when that specific Settings window was created by the current operation.

For removal, the test loads `DeviceId` from `config.json` and resolves that AssociationEndpoint directly with `DeviceInformation.CreateFromIdAsync`. A stale or missing saved ID falls back to the address-pinned paired `DeviceWatcher` for at most five seconds and refreshes `config.json`; it never performs an unpaired discovery scan while resolving an already paired mouse.

The completed tray application uses the verified Windows Settings UI flow and pinned-address connected-state checks.

## Tray application

Build and run the Windows 11 tray app:

```powershell
dotnet run --project .\MagicMouseSwitch.Tray
```

The tray app registers `Ctrl+Shift+M`, reuses the proven CLI operation services, and displays a compact no-focus WPF status overlay above the primary taskbar. Normal tray connections require paired state, pinned-address verification, and connected state; cursor movement is reserved for the **Diagnostic connect test** tray command.

Mutable application data is stored per user:

```text
%LOCALAPPDATA%\MagicMouseSwitch\config.json
%LOCALAPPDATA%\MagicMouseSwitch\logs\
```

## Windows v1.0 packaging

Publish the self-contained Windows x64 application with:

```powershell
dotnet publish .\MagicMouseSwitch.Tray\MagicMouseSwitch.Tray.csproj -c Release -p:PublishProfile=Windows-x64 -o .\release\MagicMouseSwitch-1.0.0-win-x64
```

Compile the installer with Inno Setup 6:

```powershell
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" ".\installer\MagicMouseSwitch.iss"
```

If Inno Setup was installed per-user, use:

```powershell
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" ".\installer\MagicMouseSwitch.iss"
```
