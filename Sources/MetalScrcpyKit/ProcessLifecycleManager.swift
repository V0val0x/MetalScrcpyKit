import Foundation
import Darwin

/// Thread-safe supervisor for child `Process` instances (such as `scrcpy-server` or `adb` bridges).
/// Guarantees clean `SIGTERM` -> `SIGKILL` termination on window close, timeout, or app termination
/// (`applicationWillTerminate`) so zero zombie or orphan processes remain.
public final class ProcessLifecycleManager: @unchecked Sendable {
    /// Shared process lifecycle manager singleton.
    public static let shared = ProcessLifecycleManager()

    private struct TrackedProcess {
        let process: Process
        let tag: String
    }

    private let lock = NSLock()
    private var tracked: [UUID: TrackedProcess] = [:]

    /// Creates a standalone `ProcessLifecycleManager`.
    public init() {}

    /// Registers a running (or about-to-run) `Process` and automatically unregisters it when it exits.
    /// - Parameters:
    ///   - process: The `Process` instance to supervise.
    ///   - tag: Logical group identifier (e.g. `"scrcpy"`, `"adb"`).
    /// - Returns: A unique tracking token that can be passed to `unregister(_:)`.
    @discardableResult
    public func register(_ process: Process, tag: String) -> UUID {
        let id = UUID()
        let previousHandler = process.terminationHandler
        process.terminationHandler = { [weak self] proc in
            self?.unregister(id)
            previousHandler?(proc)
        }
        lock.lock()
        tracked[id] = TrackedProcess(process: process, tag: tag)
        lock.unlock()
        return id
    }

    /// Removes a process tracking entry by its registration token.
    public func unregister(_ id: UUID) {
        lock.lock()
        tracked.removeValue(forKey: id)
        lock.unlock()
    }

    /// Returns `true` if `id` is currently tracked and its process is still running.
    public func isTracking(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = tracked[id] else { return false }
        if !entry.process.isRunning {
            tracked.removeValue(forKey: id)
            return false
        }
        return true
    }

    /// Returns the number of currently tracked running processes (pruning any exited entries).
    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        tracked = tracked.filter { $0.value.process.isRunning }
        return tracked.count
    }

    /// Terminates a single process gracefully with `SIGTERM`, escalating to `SIGKILL` after `gracePeriodMs` if still alive.
    /// Never blocks the caller's thread.
    public func terminateProcess(_ process: Process, gracePeriodMs: UInt64 = 350) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(Int(gracePeriodMs))) {
            if process.isRunning && pid > 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    /// Terminates all tracked processes matching `tag` (`SIGTERM` -> `SIGKILL` fallback).
    public func terminateProcesses(withTag tag: String, gracePeriodMs: UInt64 = 350) {
        lock.lock()
        let matches = tracked.filter { $0.value.tag == tag }
        for key in matches.keys {
            tracked.removeValue(forKey: key)
        }
        lock.unlock()

        for (_, entry) in matches {
            terminateProcess(entry.process, gracePeriodMs: gracePeriodMs)
        }
    }

    /// Terminates every tracked child process.
    /// - Parameters:
    ///   - synchronousWait: Pass `true` during `applicationWillTerminate` so macOS does not exit before `SIGKILL` cleans up stubborn subprocesses.
    ///   - gracePeriodMs: Time to wait after `SIGTERM` before escalating to `SIGKILL`.
    public func terminateAllProcesses(synchronousWait: Bool = false, gracePeriodMs: UInt64 = 250) {
        lock.lock()
        let all = Array(tracked.values)
        tracked.removeAll()
        lock.unlock()

        let running = all.map(\.process).filter { $0.isRunning }
        guard !running.isEmpty else { return }

        for proc in running {
            proc.terminate()
        }

        if synchronousWait {
            let deadline = Date().addingTimeInterval(Double(gracePeriodMs) / 1000.0)
            while Date() < deadline {
                if running.allSatisfy({ !$0.isRunning }) {
                    return
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
            for proc in running where proc.isRunning {
                let pid = proc.processIdentifier
                if pid > 0 {
                    kill(pid, SIGKILL)
                }
            }
        } else {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(Int(gracePeriodMs))) {
                for proc in running where proc.isRunning {
                    let pid = proc.processIdentifier
                    if pid > 0 {
                        kill(pid, SIGKILL)
                    }
                }
            }
        }
    }
}
