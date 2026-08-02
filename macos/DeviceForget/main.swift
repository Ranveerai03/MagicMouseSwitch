import Darwin
import DeviceSelectionCore
import Foundation
import MagicMouseSwitchServices

private func fail(_ message: String, exitCode: Int32) -> Never {
    FileHandle.standardError.write(Data("DeviceForget: \(message)\n".utf8))
    exit(exitCode)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, arguments[0] == "--address" else {
    fail("usage: DeviceForget --address <Bluetooth address>", exitCode: 64)
}

let configuredAddress = arguments[1]
do {
    let selected = try ForgetSafety.selectEligibleDevice(
        from: {
            let status = MagicMouseStatusService.currentStatus(
                configuredAddress: configuredAddress
            )
            switch status {
            case .connected(let device), .pairedButDisconnected(let device):
                return [device]
            case .unpaired:
                return []
            case .unavailable(let reason):
                throw MagicMouseServiceError(reason)
            }
        }(),
        configuredAddress: configuredAddress
    )
    print("Selected device")
    print("---------------")
    print("Name: \(selected.name)")
    print("Address: \(selected.address)")
    print("Paired: \(selected.isPaired)")
    print("Connected: \(selected.isConnected)")
    print(String(format: "Class: 0x%06X", selected.classOfDevice))
} catch {
    fail("initial selection failed: \(error)", exitCode: 2)
}

print("Type exactly: \(ForgetSafety.confirmationPhrase)")
guard let phrase = readLine(strippingNewline: true),
      ForgetSafety.confirmationIsExact(phrase) else {
    fail("confirmation did not exactly match \(ForgetSafety.confirmationPhrase)", exitCode: 3)
}

do {
    let result = try MagicMouseForgetService.run(
        configuredAddress: configuredAddress,
        event: { print("DeviceForget: \($0)") }
    )
    print("Final Forget Device AXPress result: \(result.finalAXPressResult)")
    print("Forget completed successfully.")
} catch {
    fail(String(describing: error), exitCode: 4)
}
