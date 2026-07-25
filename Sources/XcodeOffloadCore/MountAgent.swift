import DiskArbitration
import Foundation
import OSLog

public struct MountAgent {
    private let actions: MountActions

    public init(actions: MountActions = MountActions()) {
        self.actions = actions
    }

    public func run(config: StorageConfig) throws -> Never {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw CommandError("cannot create Disk Arbitration session", exitCode: 70)
        }

        let context = MountAgentContext(actions: actions, config: config)
        let opaque = Unmanaged.passRetained(context).toOpaque()
        defer {
            DASessionUnscheduleFromRunLoop(
                session,
                CFRunLoopGetCurrent(),
                CFRunLoopMode.defaultMode.rawValue
            )
            Unmanaged<MountAgentContext>.fromOpaque(opaque).release()
        }

        DARegisterDiskAppearedCallback(session, nil, mountAgentDiskEvent, opaque)
        DARegisterDiskDisappearedCallback(session, nil, mountAgentDiskEvent, opaque)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, mountAgentDescriptionChanged, opaque)
        DASessionScheduleWithRunLoop(
            session,
            CFRunLoopGetCurrent(),
            CFRunLoopMode.defaultMode.rawValue
        )
        context.trigger()
        CFRunLoopRun()
        throw CommandError("mount agent run loop stopped unexpectedly", exitCode: 70)
    }
}

private final class MountAgentContext: @unchecked Sendable {
    private let actions: MountActions
    private let config: StorageConfig
    private let queue = DispatchQueue(label: "io.github.rudironsoni.xcode-offload.mount-agent")
    private let logger = Logger(
        subsystem: "io.github.rudironsoni.xcode-offload",
        category: "mount-agent"
    )
    private var isReconciling = false
    private var retryWorkItem: DispatchWorkItem?
    private var retryDelay: TimeInterval = 1
    private var lastLoggedError: String?

    init(actions: MountActions, config: StorageConfig) {
        self.actions = actions
        self.config = config
    }

    func trigger() {
        queue.async { [self] in
            retryWorkItem?.cancel()
            retryWorkItem = nil
            guard !isReconciling else {
                return
            }
            isReconciling = true
            reconcile()
        }
    }

    private func reconcile() {
        do {
            _ = try actions.reconcile(config: config, dryRun: false)
            isReconciling = false
            retryDelay = 1
            if lastLoggedError != nil {
                logger.info("mount lifecycle recovered")
            }
            lastLoggedError = nil
        } catch {
            isReconciling = false
            let message = (error as? CommandError)?.message ?? error.localizedDescription
            if lastLoggedError != message {
                logger.error("mount reconciliation failed: \(message, privacy: .public)")
                lastLoggedError = message
            }
            guard FileManager.default.fileExists(atPath: config.root) else {
                retryDelay = 1
                return
            }
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, 30)
            let workItem = DispatchWorkItem { [weak self] in
                self?.trigger()
            }
            retryWorkItem = workItem
            queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }
}

private func mountAgentDiskEvent(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    guard let context else {
        return
    }
    Unmanaged<MountAgentContext>.fromOpaque(context).takeUnretainedValue().trigger()
}

private func mountAgentDescriptionChanged(
    _ disk: DADisk,
    _ keys: CFArray,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else {
        return
    }
    Unmanaged<MountAgentContext>.fromOpaque(context).takeUnretainedValue().trigger()
}
