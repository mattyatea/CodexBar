import Foundation

/// The small, self-contained payload sent to an SSH host for one account-sync operation.
///
/// The packaged helper does not need CodexBarCore's resource bundle for `account-sync`, so the
/// payload contains only the CLI executable and, for a mutation, the credential-free selection
/// request. The host never receives the full app or any credential material.
package enum RemoteAccountSyncTransport {
    package struct SSHRunOptions: Sendable {
        package let timeout: TimeInterval
        package let maxOutputBytes: Int
        package let label: String

        package init(timeout: TimeInterval, maxOutputBytes: Int, label: String) {
            self.timeout = timeout
            self.maxOutputBytes = maxOutputBytes
            self.label = label
        }
    }

    package static let maximumHelperBytes = 64 * 1024 * 1024
    package static let maximumPayloadBytes = 96 * 1024 * 1024

    package static func bundledHelperData(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Data
    {
        guard let url = self.bundledHelperURL(environment: environment) else {
            throw RemoteAccountSyncError.helperUnavailable
        }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty, data.count <= self.maximumHelperBytes else {
                throw RemoteAccountSyncError.payloadTooLarge
            }
            return data
        } catch let error as RemoteAccountSyncError {
            throw error
        } catch {
            throw RemoteAccountSyncError.helperUnavailable
        }
    }

    package static func bundledHelperURL(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> URL?
    {
        var candidates: [URL] = []
        if let override = environment["CODEXBAR_REMOTE_ACCOUNT_SYNC_HELPER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            candidates.append(URL(fileURLWithPath: override))
        }

        let helperName = "CodexBarCLI"
        let bundleURL = bundle.bundleURL
        if bundleURL.pathExtension == "app" {
            candidates.append(
                bundleURL
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Helpers", isDirectory: true)
                    .appendingPathComponent(helperName))
        }
        if let executableURL = bundle.executableURL {
            candidates.append(
                executableURL
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Helpers", isDirectory: true)
                    .appendingPathComponent(helperName))
        }

        var seen: Set<String> = []
        return candidates.first { candidate in
            let normalized = candidate.standardizedFileURL.path
            guard seen.insert(normalized).inserted else { return false }
            return fileManager.isExecutableFile(atPath: normalized)
        }
    }

    package static func archive(helperData: Data, requestData: Data?) throws -> Data {
        guard !helperData.isEmpty, helperData.count <= self.maximumHelperBytes else {
            throw RemoteAccountSyncError.payloadTooLarge
        }
        if let requestData, requestData.count > RemoteAccountSynchronizer.maximumRequestBytes {
            throw RemoteAccountSyncError.payloadTooLarge
        }

        var archive = Data()
        try self.appendEntry(
            named: "CodexBarCLI",
            data: helperData,
            mode: 0o700,
            to: &archive)
        if let requestData {
            try self.appendEntry(
                named: "request.json",
                data: requestData,
                mode: 0o600,
                to: &archive)
        }
        archive.append(Data(repeating: 0, count: 1024))
        guard archive.count <= self.maximumPayloadBytes else {
            throw RemoteAccountSyncError.payloadTooLarge
        }
        return archive
    }

    package static func sshBinary() throws -> String {
        guard let binary = ["/usr/bin/ssh", "/bin/ssh"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw RemoteAccountSyncError.unavailable
        }
        return binary
    }

    package static func runSSH(
        arguments: [String],
        environment: [String: String],
        inputData: Data,
        options: SSHRunOptions) async throws -> String
    {
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-account-sync-" + UUID().uuidString + ".tar")
        do {
            try inputData.write(to: inputURL, options: .atomic)
            let inputFile = try FileHandle(forReadingFrom: inputURL)
            defer {
                inputFile.closeFile()
                try? FileManager.default.removeItem(at: inputURL)
            }
            let result = try await SubprocessRunner.run(
                binary: self.sshBinary(),
                arguments: arguments,
                environment: environment,
                timeout: options.timeout,
                maxOutputBytes: options.maxOutputBytes,
                standardInput: inputFile,
                label: options.label)
            return result.stdout
        } catch let error as RemoteAccountSyncError {
            try? FileManager.default.removeItem(at: inputURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: inputURL)
            throw error
        }
    }

    package static func remoteCommand(probe: Bool) -> String {
        let invocation = probe
            ? "\"$helper\" account-sync --probe --json"
            : "\"$helper\" account-sync --stdin --json < \"$tmp/request.json\""
        var commands = [
            "set -eu",
            "umask 077",
            "tmp=\"\"",
            "for base in \"${TMPDIR:-}\" \"${HOME:-}\" /tmp; do " +
                "if [ -n \"$base\" ] && " +
                "candidate=\"$(mktemp -d \"$base/codexbar-account-sync.XXXXXXXX\" 2>/dev/null)\"; " +
                "then tmp=\"$candidate\"; break; fi; done",
            "if [ -z \"$tmp\" ]; then " +
                "echo 'Could not create a temporary directory on the remote host.' >&2; exit 70; fi",
            "cleanup() { rm -rf \"$tmp\"; }",
            "trap cleanup 0",
            "trap 'cleanup; exit 1' HUP INT TERM",
            "if ! command -v tar >/dev/null 2>&1; then " +
                "echo 'Remote host does not provide tar.' >&2; exit 127; fi",
            "if ! tar -xf - -C \"$tmp\"; then " +
                "echo 'Could not unpack the temporary account-sync helper.' >&2; exit 65; fi",
            "helper=\"$tmp/CodexBarCLI\"",
            "if [ ! -f \"$helper\" ]; then echo 'Temporary account-sync helper is missing.' >&2; exit 65; fi",
            "chmod 700 \"$helper\"",
            "if [ ! -x \"$helper\" ]; then echo 'Temporary account-sync helper is not executable.' >&2; exit 126; fi",
        ]
        if !probe {
            commands.append(
                "if [ ! -f \"$tmp/request.json\" ]; then " +
                    "echo 'Temporary account-sync request is missing.' >&2; exit 65; fi")
        }
        commands.append(invocation)
        return commands.joined(separator: "; ")
    }

    package static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appendEntry(
        named name: String,
        data: Data,
        mode: UInt64,
        to archive: inout Data) throws
    {
        let nameBytes = Array(name.utf8)
        guard !nameBytes.isEmpty, nameBytes.count <= 100 else {
            throw RemoteAccountSyncError.payloadTooLarge
        }

        var header = Data(repeating: 0, count: 512)
        self.write(nameBytes, at: 0, length: 100, to: &header)
        self.writeOctal(mode, at: 100, length: 8, to: &header)
        self.writeOctal(0, at: 108, length: 8, to: &header)
        self.writeOctal(0, at: 116, length: 8, to: &header)
        self.writeOctal(UInt64(data.count), at: 124, length: 12, to: &header)
        self.writeOctal(0, at: 136, length: 12, to: &header)
        for index in 148..<156 {
            header[index] = 0x20
        }
        header[156] = 0
        self.write(Array("ustar\0".utf8), at: 257, length: 6, to: &header)
        self.write(Array("00".utf8), at: 263, length: 2, to: &header)
        self.write(Array("codexbar".utf8), at: 265, length: 32, to: &header)
        self.write(Array("codexbar".utf8), at: 297, length: 32, to: &header)

        let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
        self.writeChecksum(checksum, to: &header)
        archive.append(header)
        archive.append(data)
        let padding = (512 - data.count % 512) % 512
        if padding > 0 {
            archive.append(Data(repeating: 0, count: padding))
        }
    }

    private static func write(
        _ bytes: [UInt8],
        at offset: Int,
        length: Int,
        to data: inout Data)
    {
        for (index, byte) in bytes.prefix(length).enumerated() {
            data[offset + index] = byte
        }
    }

    private static func writeOctal(
        _ value: UInt64,
        at offset: Int,
        length: Int,
        to data: inout Data)
    {
        let digits = String(value, radix: 8)
        let digitLength = length - 1
        let padded = String(repeating: "0", count: max(0, digitLength - digits.count)) + digits
        self.write(Array(padded.utf8), at: offset, length: digitLength, to: &data)
    }

    private static func writeChecksum(_ value: UInt64, to data: inout Data) {
        let digits = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, 6 - digits.count)) + digits
        self.write(Array(padded.utf8), at: 148, length: 6, to: &data)
        data[154] = 0
        data[155] = 0x20
    }
}
