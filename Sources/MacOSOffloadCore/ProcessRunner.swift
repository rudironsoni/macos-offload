import Darwin
import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool {
        exitCode == 0
    }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> ProcessResult

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        timeoutSeconds: TimeInterval
    ) throws -> ProcessResult
}

public extension CommandRunning {
    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        timeoutSeconds _: TimeInterval
    ) throws -> ProcessResult {
        try run(executable, arguments: arguments, environment: environment)
    }
}

public struct SystemCommandRunner: CommandRunning {
    private static let spawnLock = NSLock()

    public init() {}

    public func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> ProcessResult {
        try runProcess(
            executable,
            arguments: arguments,
            environment: environment,
            timeoutSeconds: 300
        )
    }

    public func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        timeoutSeconds: TimeInterval
    ) throws -> ProcessResult {
        try runProcess(
            executable,
            arguments: arguments,
            environment: environment,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func runProcess(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        timeoutSeconds: TimeInterval?
    ) throws -> ProcessResult {
        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }

        let spawned = try Self.spawnLock.withLock {
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            try markCloseOnExec(stdoutPipe)
            try markCloseOnExec(stderrPipe)
            let processID = try spawnProcessGroup(
                executable: executable,
                arguments: arguments,
                environment: mergedEnvironment,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe
            )
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            return (
                processID,
                ProcessOutputCapture(stdout: stdoutPipe, stderr: stderrPipe)
            )
        }
        let processID = spawned.0
        let capture = spawned.1
        capture.start()

        var status: Int32 = 0
        var timedOut = false
        if let timeoutSeconds {
            let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
            while waitpid(processID, &status, WNOHANG) == 0, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }

            if waitpid(processID, &status, WNOHANG) == 0 {
                timedOut = true
                kill(-processID, SIGTERM)

                let terminationDeadline = Date().addingTimeInterval(1)
                while waitpid(processID, &status, WNOHANG) == 0, Date() < terminationDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }

                if waitpid(processID, &status, WNOHANG) == 0 {
                    kill(-processID, SIGKILL)
                    _ = waitpid(processID, &status, 0)
                }
            }
        } else {
            _ = waitpid(processID, &status, 0)
        }

        let output = capture.finish()
        let stdoutText = String(data: output.stdout, encoding: .utf8) ?? ""
        var stderrText = String(data: output.stderr, encoding: .utf8) ?? ""
        if timedOut, let timeoutSeconds {
            if !stderrText.isEmpty && !stderrText.hasSuffix("\n") {
                stderrText.append("\n")
            }
            stderrText.append("command timed out after \(timeoutSeconds) seconds\n")
        }

        return ProcessResult(
            exitCode: timedOut ? 124 : processExitCode(status),
            stdout: stdoutText,
            stderr: stderrText
        )
    }

    private func spawnProcessGroup(
        executable: String,
        arguments: [String],
        environment: [String: String],
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            throw CommandError("cannot initialize process spawn attributes", exitCode: 71)
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        let stdoutRead = stdoutPipe.fileHandleForReading.fileDescriptor
        let stdoutWrite = stdoutPipe.fileHandleForWriting.fileDescriptor
        let stderrRead = stderrPipe.fileHandleForReading.fileDescriptor
        let stderrWrite = stderrPipe.fileHandleForWriting.fileDescriptor
        posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, stdoutRead)
        posix_spawn_file_actions_addclose(&fileActions, stderrRead)
        posix_spawn_file_actions_addclose(&fileActions, stdoutWrite)
        posix_spawn_file_actions_addclose(&fileActions, stderrWrite)

        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = ([executable] + arguments).map { strdup($0) }
        let envp = environment
            .map { strdup("\($0.key)=\($0.value)") }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var processID: pid_t = 0
        let spawnResult = executable.withCString { executablePointer in
            posix_spawn(
                &processID,
                executablePointer,
                &fileActions,
                &attributes,
                argv + [nil],
                envp + [nil]
            )
        }
        guard spawnResult == 0 else {
            throw CommandError(
                "cannot execute \(executable): \(String(cString: strerror(spawnResult)))",
                exitCode: 71
            )
        }
        return processID
    }

    private func markCloseOnExec(_ pipe: Pipe) throws {
        for descriptor in [
            pipe.fileHandleForReading.fileDescriptor,
            pipe.fileHandleForWriting.fileDescriptor
        ] {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw CommandError(
                    "cannot mark process pipe close-on-exec: \(String(cString: strerror(errno)))",
                    exitCode: 71
                )
            }
        }
    }

    private func processExitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + signal
    }
}

private final class ProcessOutputCapture: @unchecked Sendable {
    private let stdout: Pipe
    private let stderr: Pipe
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var shouldStop = false

    init(stdout: Pipe, stderr: Pipe) {
        self.stdout = stdout
        self.stderr = stderr
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            drain(
                descriptor: stdout.fileHandleForReading.fileDescriptor,
                append: { self.stdoutData.append($0) }
            )
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            drain(
                descriptor: stderr.fileHandleForReading.fileDescriptor,
                append: { self.stderrData.append($0) }
            )
            group.leave()
        }
    }

    func finish() -> (stdout: Data, stderr: Data) {
        lock.withLock {
            shouldStop = true
        }
        group.wait()
        stdout.fileHandleForReading.closeFile()
        stderr.fileHandleForReading.closeFile()
        return lock.withLock {
            (stdoutData, stderrData)
        }
    }

    private func drain(
        descriptor: Int32,
        append: @escaping (Data) -> Void
    ) {
        let originalFlags = fcntl(descriptor, F_GETFL)
        if originalFlags >= 0 {
            _ = fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK)
        }

        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let byteCount = read(descriptor, &buffer, buffer.count)
            if byteCount > 0 {
                let chunk = Data(buffer.prefix(Int(byteCount)))
                lock.withLock {
                    append(chunk)
                }
                continue
            }
            if byteCount == 0 {
                return
            }
            if errno == EINTR {
                continue
            }
            guard errno == EAGAIN || errno == EWOULDBLOCK else {
                return
            }
            if lock.withLock({ shouldStop }) {
                return
            }

            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = poll(&descriptorState, 1, 100)
        }
    }
}

public struct CommandError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public let exitCode: Int32

    public init(_ message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }

    public var description: String {
        message
    }
}
