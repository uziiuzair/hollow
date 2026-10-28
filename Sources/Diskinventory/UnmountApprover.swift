import DiskApp
import DiskArbitration
import Foundation
import os

/// Asks DiskArbitration to consult the app before any volume unmounts (a Finder eject, `diskutil unmount`), and holds
/// each unmount for at most the gate's limit while that drive's index closes. It always approves: the app never
/// dissents, so it can never be the reason an eject fails.
final class UnmountApprover: @unchecked Sendable {
    private let gate: UnmountGate
    private let log: Logger
    /// Callbacks arrive here, off main; a hold blocks only this queue.
    private let queue = DispatchQueue(label: AppIdentity.bundleID + ".unmount-approval", qos: .utility)
    /// Touched only on main (start and stop).
    private var session: DASession?

    init(gate: UnmountGate, log: Logger) {
        self.gate = gate
        self.log = log
    }

    func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        DASessionSetDispatchQueue(session, queue)
        DARegisterDiskUnmountApprovalCallback(session, nil, Self.callback, Unmanaged.passUnretained(self).toOpaque())
        self.session = session
        log.info("unmount approval registered")
    }

    func stop() {
        guard let session else { return }
        DAUnregisterCallback(session, unsafeBitCast(Self.callback, to: UnsafeMutableRawPointer.self),
                             Unmanaged.passUnretained(self).toOpaque())
        DASessionSetDispatchQueue(session, nil)
        self.session = nil
    }

    deinit { if let session { DASessionSetDispatchQueue(session, nil) } }

    private static let callback: DADiskUnmountApprovalCallback = { disk, context in
        if let context { Unmanaged<UnmountApprover>.fromOpaque(context).takeUnretainedValue().hold(disk) }
        return nil  // approve, always
    }

    /// Runs on `queue`.
    private func hold(_ disk: DADisk) {
        guard let description = DADiskCopyDescription(disk) as? [CFString: Any],
              let url = description[kDADiskDescriptionVolumePathKey] as? URL else { return }
        let path = url.resolvingSymlinksInPath().path
        let clock = ContinuousClock()
        var outcome = UnmountHold.notOpen
        let held = clock.measure { outcome = gate.approve(volumePath: path) }
        let ms = held / .milliseconds(1)
        log.info("unmount of \(path, privacy: .public) held \(Int(ms)) ms (\(String(describing: outcome), privacy: .public))")
    }
}
