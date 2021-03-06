// Copyright Marcin Krzyżanowski <marcin@krzyzanowskim.com>

import Basic
import Dispatch
import FileKit
import Foundation
import LoggerAPI
import SPMUtility

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

enum SwiftToolchain: String, RawRepresentable, Codable {
    case swift3_0_2 = "3.0.2-RELEASE"

    // Path to toolchain, relative to current process PWD
    var path: AbsolutePath {
        let projectDirectoryPath = AbsolutePath(FileKit.projectFolder)
        return projectDirectoryPath.appending(components: "Toolchains", "swift-\(self.rawValue).xctoolchain", "usr", "bin")
    }

}


class BuildToolchain {
    enum Error: Swift.Error {
        case failed(String)
    }

    private let processSet = ProcessSet()

    func build(code: String, toolchain: SwiftToolchain) throws -> Result<AbsolutePath, Error> {
        let fileSystem = Basic.localFileSystem
        let projectDirectoryPath = AbsolutePath(FileKit.projectFolder)

        let temporaryBuildDirectory = try TemporaryDirectory(prefix: ProcessInfo.processInfo.globallyUniqueString)
        let mainFilePath = temporaryBuildDirectory.path.appending(RelativePath("main.swift"))
        let binaryFilePath = temporaryBuildDirectory.path.appending(component: "main")
        let frameworksDirectory = projectDirectoryPath.appending(component: "Frameworks")

        try fileSystem.writeFileContents(mainFilePath, bytes: ByteString(encodingAsUTF8: injectCodeText + code))

        let target: String
        #if os(macOS)
            target = "x86_64-apple-macosx10.11"
        #endif
        #if os(Linux)
            target = "x86_64-unknown-linux-gnu"
        #endif

        var cmd = [String]()
        cmd += ["\(toolchain.path.pathString)/swift"]
        cmd += ["--driver-mode=swiftc"]
        cmd += ["-swift-version", "3"]
        #if DEBUG
        cmd += ["-v"]
        #endif
        cmd += ["-gnone"]
        cmd += ["-suppress-warnings"]
        cmd += ["-module-name", "SwiftPlayground"]
        // Darwin is implicitly imported with Foundation, but Glibc is not. Glibc is not on Linux.
        #if os(Linux)
            cmd += ["-module-link-name","Glibc"]
        #endif
        #if DEBUG
            cmd += ["-I", projectDirectoryPath.appending(components: "OnlinePlayground", "OnlinePlayground-\(toolchain.rawValue)", ".build", "debug").pathString]
            cmd += ["-L", projectDirectoryPath.appending(components: "OnlinePlayground", "OnlinePlayground-\(toolchain.rawValue)", ".build", "debug").pathString]
        #else
            cmd += ["-I", projectDirectoryPath.appending(components: "OnlinePlayground", "OnlinePlayground-\(toolchain.rawValue)", ".build", "release").pathString]
            cmd += ["-L", projectDirectoryPath.appending(components: "OnlinePlayground", "OnlinePlayground-\(toolchain.rawValue)", ".build", "release").pathString]
        #endif
        cmd += ["-lOnlinePlayground"]
        cmd += ["-target", target]
        #if os(macOS)
            cmd += ["-F", frameworksDirectory.pathString]
            cmd += ["-Xlinker", "-rpath", "-Xlinker", frameworksDirectory.pathString]
        #endif

        // Optimization or not
        #if os(macOS)
            cmd += ["-sanitize=address"]
        #else
            cmd += ["-O"]
        #endif
        // cmd += ["-enforce-exclusivity=checked"] // needs -Onone
        // Enable JSON-based output at some point.
        // cmd += ["-parseable-output"]
        if let sdkRoot = sdkRoot() {
            cmd += ["-sdk", sdkRoot.pathString]
        }
        cmd += ["-o", binaryFilePath.pathString]
        cmd += [mainFilePath.pathString]

        let process = Basic.Process(arguments: cmd, outputRedirection: .collect, verbose: false)
        try processSet.add(process)
        try process.launch()
        let result = try process.waitUntilExit()

        switch result.exitStatus {
        case .terminated(let exitCode) where exitCode == 0:
            return Result.success(binaryFilePath)
        case .signalled(let signal):
            return Result.failure(Error.failed("Terminated by signal \(signal)"))
        default:
            return Result.failure(Error.failed(try (result.utf8Output() + result.utf8stderrOutput()).spm_chuzzle() ?? "Terminated."))
        }
    }

    func run(binaryPath: AbsolutePath) throws -> Result<String, Error> {
        var cmd = [String]()
        #if os(macOS)
            // Use sandbox-exec on macOS. This provides some safety against arbitrary code execution.
            cmd += ["sandbox-exec", "-p", sandboxProfile()]
        #endif
        cmd += [binaryPath.pathString]

        let process = Basic.Process(arguments: cmd, environment: [:], outputRedirection: .collect, verbose: false)
        try processSet.add(process)
        try process.launch()
        let result = try process.waitUntilExit()

        // Remove container directory. Cleanup after run.
        try FileManager.default.removeItem(atPath: binaryPath.parentDirectory.pathString)

        switch result.exitStatus {
        case .terminated(let exitCode) where exitCode == 0:
            return Result.success(try result.utf8Output().spm_chuzzle() ?? "Done.")
        case .signalled(let signal):
            return Result.failure(Error.failed("Terminated by signal \(signal)"))
        default:
            return Result.failure(Error.failed(try (result.utf8Output() + result.utf8stderrOutput()).spm_chuzzle() ?? "Terminated."))
        }
    }

    private var _sdkRoot: AbsolutePath?
    private func sdkRoot() -> AbsolutePath? {
        if let sdkRoot = _sdkRoot {
            return sdkRoot
        }

        // Find SDKROOT on macOS using xcrun.
        #if os(macOS)
            let foundPath = try? Process.checkNonZeroExit(
                args: "xcrun", "--sdk", "macosx", "--show-sdk-path")
            guard let sdkRoot = foundPath?.spm_chomp(), !sdkRoot.isEmpty else {
                return nil
            }
            _sdkRoot = AbsolutePath(sdkRoot)
        #endif

        return _sdkRoot
    }
}

private func sandboxProfile() -> String {
    var output = """
    (version 1)
    (deny default)
    (import \"system.sb\")
    (allow file-read*)
    (allow process*)
    (allow sysctl*)
    (allow file-write*
    """
    for directory in Platform.darwinCacheDirectories() {
        output += "    (regex #\"^\(directory.pathString)/org\\.llvm\\.clang.*\")"
        output += "    (regex #\"^\(directory.pathString)/xcrun_db.*\")"
    }
    output += ")\n"
    return output
}

let injectCodeText = """
import OnlinePlayground;
OnlinePlayground.setup;

"""
