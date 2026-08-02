import Darwin
import DeviceSelectionCore
import Foundation
import MagicMouseSwitchServices

private func fail(_ message: String, exitCode: Int32) -> Never {
    FileHandle.standardError.write(Data("DevicePair: \(message)\n".utf8))
    exit(exitCode)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, arguments[0] == "--address" else {
    fail("usage: DevicePair --address <Bluetooth address>", exitCode: 64)
}

let configuredAddress = arguments[1]
let status = MagicMouseStatusService.currentStatus(configuredAddress: configuredAddress)
if status.isPaired {
    print("Configured address is already paired; inquiry and pairing were not started.")
    exit(0)
}
if case .unavailable(let reason) = status {
    fail("pre-inquiry status failed: \(reason)", exitCode: 2)
}

print("Type exactly: \(PairSafety.confirmationPhrase)")
guard let phrase = readLine(strippingNewline: true),
      PairSafety.confirmationIsExact(phrase) else {
    fail("confirmation did not exactly match \(PairSafety.confirmationPhrase)", exitCode: 3)
}

do {
    let result = try MagicMousePairService.run(
        configuredAddress: configuredAddress,
        event: { print("DevicePair: \($0)") }
    )
    print(String(format: "Inquiry duration: %.3f seconds", result.inquiryDuration))
    print(String(format: "Pairing duration: %.3f seconds", result.pairingDuration))
    print("Pairing result code: \(result.pairingResultCode)")
    print("Paired state: \(result.device.isPaired)")
    print("Connected state: \(result.device.isConnected)")
} catch {
    fail(String(describing: error), exitCode: 4)
}
