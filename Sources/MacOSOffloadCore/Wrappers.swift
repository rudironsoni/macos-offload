import Darwin
import Foundation

public struct WrapperRunner {
    private let runner: CommandRunning
    private let fileManager: FileManager

    public init(runner: CommandRunning = SystemCommandRunner(), fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func runXcrun(arguments: [String], config: StorageConfig) throws -> Never {
        try prepareEnvironment(config: config)
        try exec(
            "/usr/bin/xcrun",
            arguments: arguments,
            environment: wrapperEnvironment(config: config)
        )
    }

    public func runSimctl(arguments: [String], config: StorageConfig) throws -> Never {
        try prepareEnvironment(config: config)

        let result = try runner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl"] + arguments,
            environment: wrapperEnvironment(config: config),
            timeoutSeconds: 60
        )

        if result.succeeded {
            FileHandle.standardOutput.write(Data(result.stdout.utf8))
            throw ExitRequested(code: 0)
        }

        FileHandle.standardError.write(Data(result.stderr.utf8))
        FileHandle.standardOutput.write(Data(result.stdout.utf8))
        throw ExitRequested(code: result.exitCode)
    }

    public func runXcodebuild(arguments: [String], config: StorageConfig, dryRun: Bool) throws -> Never {
        try prepareEnvironment(config: config)

        let rewritten = XcodebuildArguments.rewrite(arguments: arguments, config: config)
        if dryRun {
            print((["/usr/bin/xcodebuild"] + rewritten).map(\.shellQuoted).joined(separator: " "))
            throw ExitRequested(code: 0)
        }

        try exec(
            "/usr/bin/xcodebuild",
            arguments: rewritten,
            environment: wrapperEnvironment(config: config)
        )
    }

    private func prepareEnvironment(config: StorageConfig) throws {
        _ = try MountActions(runner: runner, fileManager: fileManager).reconcile(
            config: config,
            dryRun: false
        )
        try fileManager.createDirectory(atPath: config.tmp, withIntermediateDirectories: true)
    }

    private func wrapperEnvironment(config: StorageConfig) -> [String: String] {
        [
            "TMPDIR": config.tmp.hasSuffix("/") ? config.tmp : "\(config.tmp)/",
            "NSUnbufferedIO": "YES"
        ]
    }

    private func exec(_ executable: String, arguments: [String], environment: [String: String]) throws -> Never {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { key, value in
            strdup("\(key)=\(value)")
        }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        execve(executable, argv + [nil], envp + [nil])
        throw CommandError("exec failed for \(executable): \(String(cString: strerror(errno)))")
    }
}

public struct ExitRequested: Error, Equatable {
    public let code: Int32

    public init(code: Int32) {
        self.code = code
    }
}

public enum XcodebuildArguments {
    private static let queryOnlyArguments = [
        "-list",
        "-version",
        "-showsdks",
        "-showdestinations",
        "-help",
        "-usage"
    ]

    public static func rewrite(arguments: [String], config: StorageConfig) -> [String] {
        if arguments.contains(where: { queryOnlyArguments.contains($0) }) {
            return arguments
        }

        var filtered: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-derivedDataPath" || argument == "-clonedSourcePackagesDirPath" {
                index += 2
                continue
            }

            filtered.append(argument)
            index += 1
        }

        return [
            "-derivedDataPath",
            config.mountDerivedDataMount,
            "-clonedSourcePackagesDirPath",
            config.packageCache,
            "SYMROOT=\(config.mountDerivedDataMount)/Build/Products",
            "OBJROOT=\(config.mountDerivedDataMount)/Build/Intermediates.noindex",
            "SHARED_PRECOMPS_DIR=\(config.mountDerivedDataMount)/Build/Intermediates.noindex/PrecompiledHeaders",
            "CLANG_MODULE_CACHE_PATH=\(config.mountDerivedDataMount)/ModuleCache.noindex",
            "SWIFT_MODULE_CACHE_PATH=\(config.mountDerivedDataMount)/ModuleCache.noindex"
        ] + filtered
    }
}
