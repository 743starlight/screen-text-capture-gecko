import Foundation
import Darwin

final class Cancellation {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func check() throws { if isCancelled { throw OCRError.cancelled } }
}

/// Pipes are drained independently to avoid deadlocks, including large image inputs and stderr.
/// No shell is used. Model output is always data and is never executed.
final class CLIProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let condition = NSCondition()
    private var lines = [Data]()
    private var partial = Data()
    private var byteCount = 0
    private var stdoutFinished = false
    private var tooLarge = false
    private var errorData = Data()
    private let deadline: Date
    private let cancellation: Cancellation
    private let limit: Int

    init(path: String, arguments: [String], workspace: URL, timeout: TimeInterval,
         cancellation: Cancellation = Cancellation(), outputLimit: Int = 16 * 1024 * 1024) throws {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw OCRError.missingCLI(URL(fileURLWithPath: path).lastPathComponent)
        }
        deadline = Date().addingTimeInterval(timeout)
        self.cancellation = cancellation
        limit = outputLimit
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        process.environment = CLIEnvironment.make(workspace: workspace)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                condition.lock()
                byteCount += data.count
                if byteCount > limit { tooLarge = true } else {
                    partial.append(data)
                    while let newline = partial.firstIndex(of: 10) {
                        lines.append(Data(partial[..<newline]))
                        partial.removeSubrange(...newline)
                    }
                }
                condition.broadcast()
                condition.unlock()
                if tooLarge { break }
            }
            condition.lock()
            if !partial.isEmpty { lines.append(partial); partial.removeAll() }
            stdoutFinished = true
            condition.broadcast()
            condition.unlock()
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let data = errors.fileHandleForReading.availableData
                if data.isEmpty { break }
                condition.lock()
                // Never expose raw stderr to the UI; it can contain user or credential data.
                if errorData.count < 65536 { errorData.append(data.prefix(65536 - errorData.count)) }
                condition.unlock()
            }
        }
    }

    func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func closeInput() { try? input.fileHandleForWriting.close() }

    func nextLine() throws -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            try cancellation.check()
            if tooLarge { throw OCRError.outputTooLarge }
            if Date() >= deadline { throw OCRError.timeout }
            if !lines.isEmpty { return lines.removeFirst() }
            if stdoutFinished { return nil }
            condition.wait(until: min(deadline, Date().addingTimeInterval(0.2)))
        }
    }

    func nextJSON() throws -> [String: Any]? {
        while let line = try nextLine() {
            if line.isEmpty { continue }
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw OCRError.invalidResponse
            }
            return object
        }
        return nil
    }

    func finish() throws -> Int32 {
        while process.isRunning {
            try cancellation.check()
            if Date() >= deadline { throw OCRError.timeout }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    func stop() {
        closeInput()
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    func classifiedError(name: String) -> OCRError {
        condition.lock(); let message = String(data: errorData, encoding: .utf8)?.lowercased() ?? ""; condition.unlock()
        return Self.classify(message, name: name)
    }

    static func classify(_ message: String, name: String) -> OCRError {
        let message = message.lowercased()
        if message.contains("rate limit") || message.contains("usage limit") || message.contains("quota") || message.contains("429") {
            return .usageLimit(name)
        }
        if message.contains("login") || message.contains("not logged") || message.contains("unauthorized") || message.contains("401") || message.contains("authentication") {
            return .loginRequired(name)
        }
        return .cliFailed(name)
    }

    static func run(path: String, arguments: [String], workspace: URL, timeout: TimeInterval = 10,
                    cancellation: Cancellation = Cancellation(), allowedExitCodes: Set<Int32> = [0]) throws -> String {
        let child = try CLIProcess(path: path, arguments: arguments, workspace: workspace,
                                   timeout: timeout, cancellation: cancellation)
        defer { child.stop() }
        child.closeInput()
        var data = Data()
        while let line = try child.nextLine() { data.append(line); data.append(10) }
        guard allowedExitCodes.contains(try child.finish()) else { throw child.classifiedError(name: URL(fileURLWithPath: path).lastPathComponent) }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
