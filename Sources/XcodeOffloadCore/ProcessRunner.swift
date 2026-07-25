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

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let capture = ProcessOutputCapture(stdout: stdoutPipe, stderr: stderrPipe)
        let processID = try spawnProcessGroup(
            executable: executable,
            arguments: arguments,
            environment: mergedEnvironment,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
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

    init(stdout: Pipe, stderr: Pipe) {
        self.stdout = stdout
        self.stderr = stderr
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            lock.withLock {
                stdoutData = data
            }
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            lock.withLock {
                stderrData = data
            }
            group.leave()
        }
    }

    func finish() -> (stdout: Data, stderr: Data) {
        group.wait()
        return lock.withLock {
            (stdoutData, stderrData)
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
