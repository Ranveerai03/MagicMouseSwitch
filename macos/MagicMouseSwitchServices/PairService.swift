import DeviceSelectionCore
import Foundation
import IOBluetooth
import IOKit

private let inquiryTimeoutSeconds: TimeInterval = 30
private let pairingTimeoutSeconds: TimeInterval = 60
private let connectionTimeoutSeconds: TimeInterval = 15
private let runLoopSliceSeconds: TimeInterval = 0.05
private let connectionPollingSeconds: TimeInterval = 0.25

private struct BluetoothDeviceRecord {
    let bluetoothDevice: IOBluetoothDevice
    let snapshot: PairedBluetoothDevice
}

private enum PairingTerminalState {
    case waiting
    case completed(resultCode: IOReturn)
    case stoppedForInteractiveChallenge(description: String)
}

enum InquiryTerminalDecision: Equatable {
    case succeededAfterPinnedMatch
    case failed(error: Int32, aborted: Bool)
    case timedOut
}

struct InquiryLifecycleState: Equatable {
    private(set) var startedCallbackCount = 0
    private(set) var deviceFoundCallbackCount = 0
    private(set) var completionCallbackCount = 0
    private(set) var pinnedMatchFound = false
    private(set) var stopRequested = false
    private(set) var terminalDecision: InquiryTerminalDecision?

    mutating func recordStarted() {
        startedCallbackCount += 1
    }

    mutating func recordDeviceFound(matchesPinned: Bool) -> Bool {
        deviceFoundCallbackCount += 1
        guard terminalDecision == nil, matchesPinned, !pinnedMatchFound else {
            return false
        }
        pinnedMatchFound = true
        stopRequested = true
        return true
    }

    @discardableResult
    mutating func recordCompletion(error: Int32, aborted: Bool) -> Bool {
        completionCallbackCount += 1
        guard terminalDecision == nil else { return false }
        terminalDecision = pinnedMatchFound && stopRequested
            ? .succeededAfterPinnedMatch
            : .failed(error: error, aborted: aborted)
        return true
    }

    @discardableResult
    mutating func recordTimeout() -> Bool {
        guard terminalDecision == nil else { return false }
        terminalDecision = .timedOut
        return true
    }

    var logDescription: String {
        "startedCallbacks=\(startedCallbackCount); "
            + "deviceFoundCallbacks=\(deviceFoundCallbackCount); "
            + "pinnedMatchFound=\(pinnedMatchFound); "
            + "stopRequested=\(stopRequested); "
            + "completionCallbacks=\(completionCallbackCount); "
            + "terminal=\(String(describing: terminalDecision))"
    }
}

final class InquiryObjectRetainer {
    private var retainedDelegate: AnyObject?
    private var retainedInquiry: AnyObject?

    func retain(delegate: AnyObject, inquiry: AnyObject) {
        retainedDelegate = delegate
        retainedInquiry = inquiry
    }

    func releaseAfterCompletion() {
        retainedInquiry = nil
        retainedDelegate = nil
    }
}

private struct InquirySessionResult {
    let pinnedDevices: [IOBluetoothDevice]
    let startReturnCode: IOReturn?
    let deviceFoundCallbackCount: Int
    let completionError: IOReturn
    let completionAborted: Bool
    let stopReturnCode: IOReturn?
}

private struct InquirySessionFailure: Error, CustomStringConvertible {
    let message: String
    let startReturnCode: IOReturn?
    let deviceFoundCallbackCount: Int
    let completionError: IOReturn?
    let completionAborted: Bool?
    let pinnedAddressFound: Bool

    var description: String { message }
}

private final class InquirySession: NSObject, IOBluetoothDeviceInquiryDelegate,
    @unchecked Sendable {
    let normalizedPinnedAddress: String
    let event: MagicMouseEventHandler
    private let condition = NSCondition()
    private let retainer = InquiryObjectRetainer()
    private var lifecycle = InquiryLifecycleState()
    private var pinnedDevices: [IOBluetoothDevice] = []
    private var inquiry: IOBluetoothDeviceInquiry?
    private var stopReturnCode: IOReturn?
    private var stopCallCompleted = false
    private var completionError: IOReturn = kIOReturnError
    private var completionReceived = false
    private var completionAborted = false
    private var startReturnCode: IOReturn?
    private let deadline: Date

    init(
        normalizedPinnedAddress: String,
        deadline: Date,
        event: @escaping MagicMouseEventHandler
    ) {
        self.normalizedPinnedAddress = normalizedPinnedAddress
        self.event = event
        self.deadline = deadline
    }

    func run() throws -> InquirySessionResult {
        if Thread.isMainThread {
            startOnMainRunLoop()
            while terminalDecision() == nil && Date() < deadline {
                _ = RunLoop.main.run(
                    mode: .default,
                    before: min(Date().addingTimeInterval(runLoopSliceSeconds), deadline)
                )
            }
        } else {
            DispatchQueue.main.async { [self] in
                startOnMainRunLoop()
            }
            condition.lock()
            while (lifecycle.terminalDecision == nil
                   || (lifecycle.stopRequested && !stopCallCompleted))
                    && Date() < deadline {
                condition.wait(until: deadline)
            }
            condition.unlock()
        }

        var timedOut = false
        condition.lock()
        if lifecycle.terminalDecision == nil {
            timedOut = lifecycle.recordTimeout()
        }
        let decision = lifecycle.terminalDecision
        let stateDescription = lifecycle.logDescription
        let devices = pinnedDevices
        let completionError = self.completionError
        let completionReceived = self.completionReceived
        let completionAborted = self.completionAborted
        let stopReturnCode = self.stopReturnCode
        let startReturnCode = self.startReturnCode
        let deviceFoundCallbackCount = lifecycle.deviceFoundCallbackCount
        let pinnedAddressFound = lifecycle.pinnedMatchFound
        condition.unlock()

        if timedOut {
            performOnMainSync { [self] in
                let code = inquiry?.stop() ?? kIOReturnNotOpen
                event("inquiry timeout stop code \(code); state \(stateDescription)")
            }
        }
        performOnMainSync { [self] in
            inquiry?.delegate = nil
            inquiry = nil
            retainer.releaseAfterCompletion()
        }

        switch decision {
        case .succeededAfterPinnedMatch:
            return InquirySessionResult(
                pinnedDevices: devices,
                startReturnCode: startReturnCode,
                deviceFoundCallbackCount: deviceFoundCallbackCount,
                completionError: completionError,
                completionAborted: completionAborted,
                stopReturnCode: stopReturnCode
            )
        case let .failed(error, aborted):
            throw InquirySessionFailure(
                message: "inquiry completed before pinned match; error \(error); "
                    + "aborted \(aborted); state \(stateDescription)",
                startReturnCode: startReturnCode,
                deviceFoundCallbackCount: deviceFoundCallbackCount,
                completionError: completionReceived ? completionError : nil,
                completionAborted: completionReceived ? completionAborted : nil,
                pinnedAddressFound: pinnedAddressFound
            )
        case .timedOut:
            throw InquirySessionFailure(
                message: "inquiry timed out; state \(stateDescription)",
                startReturnCode: startReturnCode,
                deviceFoundCallbackCount: deviceFoundCallbackCount,
                completionError: completionReceived ? completionError : nil,
                completionAborted: completionReceived ? completionAborted : nil,
                pinnedAddressFound: pinnedAddressFound
            )
        case nil:
            throw InquirySessionFailure(
                message: "inquiry ended without terminal state",
                startReturnCode: startReturnCode,
                deviceFoundCallbackCount: deviceFoundCallbackCount,
                completionError: completionReceived ? completionError : nil,
                completionAborted: completionReceived ? completionAborted : nil,
                pinnedAddressFound: pinnedAddressFound
            )
        }
    }

    private func startOnMainRunLoop() {
        precondition(Thread.isMainThread)
        guard terminalDecision() == nil else { return }
        guard let createdInquiry = IOBluetoothDeviceInquiry(delegate: self) else {
            finishWithoutCallback(error: kIOReturnNoResources)
            return
        }
        inquiry = createdInquiry
        retainer.retain(delegate: self, inquiry: createdInquiry)
        let remainingSeconds = max(1, min(inquiryTimeoutSeconds, deadline.timeIntervalSinceNow))
        createdInquiry.inquiryLength = UInt8(ceil(remainingSeconds))
        createdInquiry.updateNewDeviceNames = false
        event(
            "inquiry object created on main run loop; length \(createdInquiry.inquiryLength); "
                + "update names \(createdInquiry.updateNewDeviceNames); search criteria default all classic"
        )
        let startCode = createdInquiry.start()
        condition.lock()
        startReturnCode = startCode
        condition.unlock()
        event("inquiry start returned \(startCode); callback thread main=\(Thread.isMainThread)")
        if startCode != kIOReturnSuccess {
            finishWithoutCallback(error: startCode)
        }
    }

    private func finishWithoutCallback(error: IOReturn) {
        condition.lock()
        completionError = error
        let accepted = lifecycle.recordCompletion(error: error, aborted: false)
        condition.broadcast()
        condition.unlock()
        if accepted {
            event("inquiry terminated before callbacks; error \(error)")
        }
    }

    private func terminalDecision() -> InquiryTerminalDecision? {
        condition.lock()
        defer { condition.unlock() }
        return lifecycle.terminalDecision
    }

    private func performOnMainSync(_ work: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private func stateDescription() -> String {
        condition.lock()
        defer { condition.unlock() }
        return lifecycle.logDescription
    }

    func deviceInquiryStarted(_ sender: IOBluetoothDeviceInquiry) {
        condition.lock()
        lifecycle.recordStarted()
        let state = lifecycle.logDescription
        condition.unlock()
        event("inquiry started; callback thread main=\(Thread.isMainThread); state \(state)")
    }

    func deviceInquiryDeviceFound(
        _ sender: IOBluetoothDeviceInquiry,
        device: IOBluetoothDevice
    ) {
        let rawName = device.name ?? "<nil>"
        let rawAddress = device.addressString ?? "<nil>"
        let normalizedAddress = BluetoothAddressNormalizer.normalize(rawAddress)
        let matchesPinned = normalizedAddress == normalizedPinnedAddress
        condition.lock()
        let shouldStop = lifecycle.recordDeviceFound(matchesPinned: matchesPinned)
        if shouldStop {
            pinnedDevices.append(device)
        }
        let state = lifecycle.logDescription
        condition.unlock()
        event(
            String(
                format: "inquiry device found; raw name %@; raw address %@; normalized address %@; classOfDevice 0x%06X; matches pinned %@; callback thread main=%@; state %@",
                rawName,
                rawAddress,
                normalizedAddress ?? "<invalid>",
                device.classOfDevice,
                matchesPinned.description,
                Thread.isMainThread.description,
                state
            )
        )
        guard shouldStop else { return }
        let code = sender.stop()
        condition.lock()
        stopReturnCode = code
        stopCallCompleted = true
        let afterStopState = lifecycle.logDescription
        condition.broadcast()
        condition.unlock()
        event("pinned address discovered; inquiry stop code \(code); state \(afterStopState)")
    }

    func deviceInquiryUpdatingDeviceNamesStarted(
        _ sender: IOBluetoothDeviceInquiry,
        devicesRemaining: UInt32
    ) {
        event(
            "inquiry name updates started; remaining \(devicesRemaining); "
                + "callback thread main=\(Thread.isMainThread); state \(stateDescription())"
        )
    }

    func deviceInquiryDeviceNameUpdated(
        _ sender: IOBluetoothDeviceInquiry,
        device: IOBluetoothDevice,
        devicesRemaining: UInt32
    ) {
        let rawName = device.name ?? "<nil>"
        let rawAddress = device.addressString ?? "<nil>"
        let normalizedAddress = BluetoothAddressNormalizer.normalize(rawAddress)
        let matchesPinned = normalizedAddress == normalizedPinnedAddress
        event(
            String(
                format: "inquiry device name updated; raw name %@; raw address %@; normalized address %@; classOfDevice 0x%06X; matches pinned %@; remaining %u; callback thread main=%@; state %@",
                rawName,
                rawAddress,
                normalizedAddress ?? "<invalid>",
                device.classOfDevice,
                matchesPinned.description,
                devicesRemaining,
                Thread.isMainThread.description,
                stateDescription()
            )
        )
    }

    func deviceInquiryComplete(
        _ sender: IOBluetoothDeviceInquiry,
        error: IOReturn,
        aborted: Bool
    ) {
        condition.lock()
        completionError = error
        completionReceived = true
        completionAborted = aborted
        let accepted = lifecycle.recordCompletion(error: error, aborted: aborted)
        let foundCallbackCount = lifecycle.deviceFoundCallbackCount
        let state = lifecycle.logDescription
        condition.broadcast()
        condition.unlock()
        event(
            "inquiry completed; error \(error); aborted \(aborted); "
                + "device-found callbacks before completion \(foundCallbackCount); "
                + "callback thread main=\(Thread.isMainThread); state \(state); "
                + "completion accepted \(accepted)"
        )
    }
}

private final class PairDelegate: NSObject, IOBluetoothDevicePairDelegate {
    let event: MagicMouseEventHandler
    private(set) var terminalState = PairingTerminalState.waiting
    private var didRequestStop = false

    init(event: @escaping MagicMouseEventHandler) {
        self.event = event
    }

    private func applyDecision(
        for callback: PairingCallbackKind,
        sender: Any,
        description: String? = nil
    ) {
        switch PairSafety.decision(for: callback) {
        case .continueWaiting:
            return
        case .completed(let resultCode):
            terminalState = .completed(resultCode: resultCode)
        case .stopAndReport:
            let detail = description ?? "unexpected interactive request"
            guard !didRequestStop else { return }
            didRequestStop = true
            terminalState = .stoppedForInteractiveChallenge(description: detail)
            guard let pairing = sender as? IOBluetoothDevicePair else { return }
            event("refusing automatic response; stopping pairing")
            pairing.stop()
        }
    }

    func devicePairingStarted(_ sender: Any) {
        event("pairing started")
        applyDecision(for: .pairingStarted, sender: sender)
    }

    func devicePairingConnecting(_ sender: Any) {
        event("pairing connecting")
        applyDecision(for: .connecting, sender: sender)
    }

    func devicePairingConnected(_ sender: Any) {
        event("pairing baseband connected")
        applyDecision(for: .connected, sender: sender)
    }

    func devicePairingPINCodeRequest(_ sender: Any) {
        event("PIN code request")
        applyDecision(for: .pinCodeRequest, sender: sender, description: "PIN code request")
    }

    func devicePairingUserConfirmationRequest(
        _ sender: Any,
        numericValue: BluetoothNumericValue
    ) {
        event("user confirmation request; numeric value \(numericValue)")
        applyDecision(
            for: .userConfirmationRequest(numericValue: numericValue),
            sender: sender,
            description: "user confirmation request; numeric value \(numericValue)"
        )
    }

    func devicePairingUserPasskeyNotification(_ sender: Any, passkey: BluetoothPasskey) {
        event("passkey notification; passkey \(passkey)")
        applyDecision(
            for: .passkeyNotification(passkey: passkey),
            sender: sender,
            description: "passkey notification; passkey \(passkey)"
        )
    }

    func deviceSimplePairingComplete(_ sender: Any, status: BluetoothHCIEventStatus) {
        event("simple pairing completed; status \(status)")
        applyDecision(for: .simplePairingComplete(status: status), sender: sender)
    }

    func devicePairingFinished(_ sender: Any, error: IOReturn) {
        event("pairing completed; result \(error)")
        applyDecision(for: .pairingFinished(resultCode: error), sender: sender)
    }
}

public enum MagicMousePairService {
    public static func run(
        configuredAddress: String = magicMousePinnedAddress,
        event: @escaping MagicMouseEventHandler = { _ in }
    ) throws -> PairOperationResult {
        let normalizedAddress: String
        do {
            normalizedAddress = try PairSafety.normalizedConfiguredAddress(configuredAddress)
            try PairSafety.requireAddressIsUnpaired(
                in: readPairedDevices(),
                configuredAddress: configuredAddress
            )
        } catch {
            throw serviceError("pre-inquiry validation failed", error)
        }

        let settingsCoordinator = PairSystemSettingsCoordinator(event: event)
        var completionGate = PairOperationCompletionGate()
        defer {
            if completionGate.recordCompletion() {
                settingsCoordinator.restoreAfterPairing()
            }
        }
        var settingsState = try settingsCoordinator.prepareBeforeInquiry()
        event("searching for pinned address \(normalizedAddress)")
        let inquiryDeadline = Date().addingTimeInterval(inquiryTimeoutSeconds)
        let inquiryStart = ContinuousClock.now
        var inquiryResult: InquirySessionResult?
        while inquiryResult == nil {
            settingsState.inquiryAttemptNumber += 1
            settingsCoordinator.updateState(settingsState)
            let attempt = settingsState.inquiryAttemptNumber
            event("inquiry attempt number \(attempt)")
            guard Date() < inquiryDeadline else {
                let inquiryDuration = elapsedSeconds(since: inquiryStart)
                event(String(format: "inquiry duration %.3f seconds", inquiryDuration))
                throw MagicMouseServiceError("30-second overall inquiry timeout expired")
            }
            let inquirySession = InquirySession(
                normalizedPinnedAddress: normalizedAddress,
                deadline: inquiryDeadline,
                event: event
            )
            do {
                let result = try inquirySession.run()
                event(
                    "inquiry attempt \(attempt) result: start \(result.startReturnCode.map(String.init) ?? "<nil>"); "
                        + "device-found callbacks \(result.deviceFoundCallbackCount); "
                        + "completion error \(result.completionError); aborted \(result.completionAborted); "
                        + "pinned address found true"
                )
                inquiryResult = result
            } catch let failure as InquirySessionFailure {
                let observation = PairInquiryRetryObservation(
                    attemptNumber: attempt,
                    startReturnCode: failure.startReturnCode,
                    deviceFoundCallbackCount: failure.deviceFoundCallbackCount,
                    completionError: failure.completionError,
                    pinnedAddressFound: failure.pinnedAddressFound,
                    bluetoothSettingsOpenRecently: settingsState.bluetoothSettingsOpenRecently
                )
                let retry = PairSettingsContentionPolicy.shouldRetry(observation)
                event(
                    "inquiry attempt \(attempt) result: start "
                        + "\(failure.startReturnCode.map(String.init) ?? "<nil>"); "
                        + "device-found callbacks \(failure.deviceFoundCallbackCount); "
                        + "completion error \(failure.completionError.map(String.init) ?? "<nil>"); "
                        + "aborted \(failure.completionAborted.map(String.init) ?? "<nil>"); "
                        + "pinned address found \(failure.pinnedAddressFound)"
                )
                event("inquiry retry eligibility decision: \(retry)")
                guard retry else {
                    let inquiryDuration = elapsedSeconds(since: inquiryStart)
                    event(String(format: "inquiry duration %.3f seconds", inquiryDuration))
                    throw MagicMouseServiceError(failure.description)
                }
                try settingsCoordinator.prepareBeforeRetry(&settingsState)
            }
        }
        let inquiryDuration = elapsedSeconds(since: inquiryStart)
        event(String(format: "inquiry duration %.3f seconds", inquiryDuration))
        guard let inquiryResult else {
            throw MagicMouseServiceError("inquiry completed without a result")
        }
        event("inquiry terminal completion error \(inquiryResult.completionError)")
        if let stopCode = inquiryResult.stopReturnCode,
           stopCode != kIOReturnSuccess {
            throw MagicMouseServiceError("inquiry stop returned \(stopCode)")
        }

        let records = inquiryResult.pinnedDevices.map {
            BluetoothDeviceRecord(bluetoothDevice: $0, snapshot: bluetoothSnapshot($0))
        }
        let selected: PairedBluetoothDevice
        do {
            selected = try PairSafety.selectDiscoveredDevice(
                from: records.map(\.snapshot),
                configuredAddress: configuredAddress
            )
        } catch {
            throw serviceError("discovered-device validation failed", error)
        }
        guard let record = records.first(where: { $0.snapshot == selected }) else {
            throw MagicMouseServiceError("validated discovered device could not be resolved")
        }
        event(
            String(
                format: "selected device: %@, %@, class 0x%06X",
                selected.name,
                selected.address,
                selected.classOfDevice
            )
        )

        do {
            try PairSafety.validateUnpairedCandidate(
                bluetoothSnapshot(record.bluetoothDevice),
                configuredAddress: configuredAddress
            )
            try PairSafety.requireAddressIsUnpaired(
                in: readPairedDevices(),
                configuredAddress: configuredAddress
            )
        } catch {
            throw serviceError("final pre-pair validation failed", error)
        }

        let delegate = PairDelegate(event: event)
        guard let pairing = IOBluetoothDevicePair(device: record.bluetoothDevice) else {
            throw MagicMouseServiceError("could not create IOBluetoothDevicePair")
        }
        pairing.delegate = delegate
        let pairingStart = ContinuousClock.now
        let pairingDeadline = Date().addingTimeInterval(pairingTimeoutSeconds)
        let pairingStartCode = pairing.start()
        guard pairingStartCode == kIOReturnSuccess else {
            throw MagicMouseServiceError("pairing start returned \(pairingStartCode)")
        }
        while case .waiting = delegate.terminalState, Date() < pairingDeadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: min(Date().addingTimeInterval(runLoopSliceSeconds), pairingDeadline)
            )
        }
        let pairingDuration = elapsedSeconds(since: pairingStart)
        let resultCode: IOReturn
        switch delegate.terminalState {
        case .waiting:
            pairing.stop()
            throw MagicMouseServiceError("pairing timed out after 60 seconds")
        case .stoppedForInteractiveChallenge(let description):
            throw MagicMouseServiceError("pairing stopped after \(description)")
        case .completed(let code):
            resultCode = code
        }
        event(
            String(
                format: "pairing duration %.3f seconds; result %d",
                pairingDuration,
                resultCode
            )
        )
        guard resultCode == kIOReturnSuccess else {
            throw MagicMouseServiceError("pairing completed with \(resultCode)")
        }

        var verified: PairedBluetoothDevice
        do {
            verified = try PairSafety.selectVerifiedPairedDevice(
                from: readPairedDevices(),
                configuredAddress: configuredAddress
            )
        } catch {
            throw serviceError("post-pair verification failed", error)
        }
        let connectionDeadline = Date().addingTimeInterval(connectionTimeoutSeconds)
        while !verified.isConnected && Date() < connectionDeadline {
            Thread.sleep(forTimeInterval: connectionPollingSeconds)
            do {
                verified = try PairSafety.selectVerifiedPairedDevice(
                    from: readPairedDevices(),
                    configuredAddress: configuredAddress
                )
            } catch {
                throw serviceError("connection polling failed", error)
            }
        }
        guard verified.isConnected else {
            throw MagicMouseServiceError("paired device did not connect within 15 seconds")
        }
        return PairOperationResult(
            inquiryDuration: inquiryDuration,
            pairingDuration: pairingDuration,
            pairingResultCode: resultCode,
            device: verified
        )
    }
}
