import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct RemoteAccountSyncTests {
    @Test
    func `selection round trips without credential material`() throws {
        let request = RemoteAccountSyncRequest(
            provider: "claude",
            selection: .claudeSwap(slot: 3, email: "person@example.com"))

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(RemoteAccountSyncRequest.self, from: data)

        #expect(decoded == request)
        #expect(String(decoding: data, as: UTF8.self).contains("accessToken") == false)
        #expect(String(decoding: data, as: UTF8.self).contains("refreshToken") == false)
    }

    @Test
    func `ssh arguments stream a temporary receiver command`() throws {
        let arguments = try RemoteAccountSynchronizer.arguments(host: "builder@example.com")

        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("StrictHostKeyChecking=yes"))
        #expect(arguments.contains("RemoteCommand=none"))
        #expect(arguments.contains("ConnectTimeout=5") == false)
        #expect(arguments.contains("ForwardAgent=no"))
        #expect(arguments.contains("ClearAllForwardings=yes"))
        #expect(arguments.contains("-T"))
        let remoteCommand = arguments.last ?? ""
        #expect(remoteCommand.contains("account-sync"))
        #expect(remoteCommand.contains("--stdin"))
        #expect(remoteCommand.contains("--json"))
        #expect(arguments.contains("-n") == false)
        #expect(remoteCommand.contains("tar -xf -"))
        #expect(remoteCommand.contains("mktemp -d"))
        #expect(remoteCommand.contains("/Applications/CodexBar.app") == false)
        #expect(remoteCommand.contains("command -v codexbar") == false)
    }

    @Test
    func `remote target normalizes operating system and architecture aliases`() throws {
        let linuxAMD64 = try RemoteAccountSyncTarget(os: "Linux", architecture: "amd64")
        #expect(linuxAMD64.operatingSystem == .linux)
        #expect(linuxAMD64.architecture == .x86_64)
        #expect(linuxAMD64.helperKey == "linux-x86_64")
        #expect(linuxAMD64.displayName == "Linux x86_64")

        let macARM = try RemoteAccountSyncTarget(os: "Darwin", architecture: "arm64")
        #expect(macARM.operatingSystem == .macOS)
        #expect(macARM.architecture == .arm64)
        #expect(macARM.helperKey == "macos-universal")

        #expect(throws: RemoteAccountSyncError.unsupportedRemoteTarget("FreeBSD sparc64")) {
            try RemoteAccountSyncTarget(os: "FreeBSD", architecture: "sparc64")
        }
    }

    @Test
    func `platform probe output ignores login noise and selects the last marker`() throws {
        let target = try RemoteAccountSyncTransport.target(
            fromProbeOutput: "welcome\ncodexbar-remote-target:Linux:amd64\n")

        #expect(target.operatingSystem == .linux)
        #expect(target.architecture == .x86_64)
        #expect(target.helperKey == "linux-x86_64")
    }

    @Test
    func `platform arguments use the same OpenSSH configuration`() throws {
        let arguments = try RemoteAccountSynchronizer.platformArguments(host: "builder@example.com")

        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("StrictHostKeyChecking=yes"))
        #expect(arguments.contains("ForwardAgent=no"))
        #expect(arguments.contains("ClearAllForwardings=yes"))
        #expect(arguments.contains("-T"))
        #expect((arguments.last ?? "").contains("uname -s"))
        #expect((arguments.last ?? "").contains("codexbar-remote-target"))
    }

    @Test
    func `target helper override resolves from the platform directory`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-account-sync-helper-test-" + UUID().uuidString)
        let helper = root
            .appendingPathComponent("linux-x86_64", isDirectory: true)
            .appendingPathComponent("CodexBarCLI")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("helper".utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: helper.path)

        let target = try RemoteAccountSyncTarget(os: "Linux", architecture: "x86_64")
        let resolved = RemoteAccountSyncTransport.bundledHelperURL(
            for: target,
            environment: ["CODEXBAR_REMOTE_ACCOUNT_SYNC_HELPERS_DIR": root.path])

        #expect(resolved?.standardizedFileURL == helper.standardizedFileURL)
    }

    @Test
    func `transport accepts release-sized Linux helpers`() {
        #expect(RemoteAccountSyncTransport.maximumHelperBytes >= 128 * 1024 * 1024)
        #expect(RemoteAccountSyncTransport.maximumPayloadBytes > RemoteAccountSyncTransport.maximumHelperBytes)
    }

    @Test
    func `host validation rejects shell input`() {
        #expect(throws: RemoteAccountSyncError.invalidHost) {
            try RemoteAccountSynchronizer.validateHost("builder; touch /tmp/pwned")
        }
        #expect(throws: RemoteAccountSyncError.invalidHost) {
            try RemoteAccountSynchronizer.validateHost("-oProxyCommand=evil")
        }
    }

    @Test
    func `synchronizer decodes successful remote response`() async {
        let synchronizer = RemoteAccountSynchronizer { _, _, _ in
            let response = RemoteAccountSyncResponse(
                status: "applied",
                provider: "codex",
                detail: "Codex system account selected")
            let responseData = try JSONEncoder().encode(response)
            return String(decoding: responseData, as: UTF8.self)
        }

        let results = await synchronizer.synchronize(
            hosts: ["remote.example", "remote.example"],
            request: RemoteAccountSyncRequest(
                provider: "codex",
                selection: .codex(email: "person@example.com", workspaceAccountID: nil)))

        #expect(results == [RemoteAccountSyncHostResult(host: "remote.example", succeeded: true)])
    }

    @Test
    func `synchronizer selects a helper after probing each remote target`() async {
        let synchronizer = RemoteAccountSynchronizer(
            runner: { _, _, payload in
                #expect(payload.contains(0xA5))
                let response = RemoteAccountSyncResponse(
                    status: "applied",
                    provider: "codex",
                    detail: "Codex system account selected")
                let responseData = try JSONEncoder().encode(response)
                return String(decoding: responseData, as: UTF8.self)
            },
            platformRunner: { _, _ in
                "login message\ncodexbar-remote-target:Linux:amd64\n"
            },
            helperDataProvider: { target, _ in
                #expect(target?.helperKey == "linux-x86_64")
                return Data([0xA5])
            })

        let results = await synchronizer.synchronize(
            hosts: ["remote.example"],
            request: RemoteAccountSyncRequest(
                provider: "codex",
                selection: .codex(email: "person@example.com", workspaceAccountID: nil)))

        #expect(results == [RemoteAccountSyncHostResult(host: "remote.example", succeeded: true)])
    }

    @Test
    func `connectivity arguments stream a read only temporary probe`() throws {
        let arguments = try RemoteAccountConnectivityTester.arguments(host: "builder@example.com")

        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("StrictHostKeyChecking=yes"))
        #expect(arguments.contains("RemoteCommand=none"))
        #expect(arguments.contains("ConnectTimeout=5") == false)
        #expect(arguments.contains("ForwardAgent=no"))
        #expect(arguments.contains("ClearAllForwardings=yes"))
        #expect(arguments.contains("-T"))
        #expect(arguments.contains("-n") == false)
        let remoteCommand = arguments.last ?? ""
        #expect(remoteCommand.contains("--stdin") == false)
        #expect(remoteCommand.contains("account-sync --probe --json"))
        #expect(remoteCommand.contains("tar -xf -"))
        #expect(remoteCommand.contains("mktemp -d"))
        #expect(remoteCommand.contains("/Applications/CodexBar.app") == false)
        #expect(remoteCommand.contains("command -v codexbar") == false)
    }

    @Test
    func `connectivity check reports temporary helper output`() async {
        let tester = RemoteAccountConnectivityTester { _, _ in
            let response = RemoteAccountSyncProbeResponse(cliVersion: "0.63.1")
            let data = try! JSONEncoder().encode(response)
            return String(decoding: data, as: UTF8.self)
        }

        let results = await tester.check(hosts: ["remote.example", "remote.example"])

        #expect(results == [
            RemoteAccountConnectivityResult(
                host: "remote.example",
                succeeded: true,
                detail: "0.63.1 · account-sync v1"),
        ])
    }

    @Test
    func `ssh environment keeps custom agent variables`() async {
        let tester = RemoteAccountConnectivityTester { _, environment in
            guard environment["CUSTOM_SSH_AGENT"] == "/tmp/custom-agent.sock" else {
                throw RemoteAccountSyncError.commandFailed("custom SSH environment was dropped")
            }
            let response = RemoteAccountSyncProbeResponse(cliVersion: "0.63.1")
            let data = try JSONEncoder().encode(response)
            return String(decoding: data, as: UTF8.self)
        }

        let results = await tester.check(
            hosts: ["remote.example"],
            environment: ["CUSTOM_SSH_AGENT": "/tmp/custom-agent.sock"])

        #expect(results == [
            RemoteAccountConnectivityResult(
                host: "remote.example",
                succeeded: true,
                detail: "0.63.1 · account-sync v1"),
        ])
    }

    @Test
    func `connectivity check returns a safe failure without applying an account`() async {
        let tester = RemoteAccountConnectivityTester { _, _ in
            throw RemoteAccountSyncError.commandFailed("permission denied\nprivate detail")
        }

        let results = await tester.check(hosts: ["remote.example"])

        #expect(results == [
            RemoteAccountConnectivityResult(
                host: "remote.example",
                succeeded: false,
                errorDescription: "Remote account sync failed: permission denied private detail"),
        ])
    }

    @Test
    func `temporary archive keeps helper and request separate`() throws {
        let helper = Data([0, 1, 2, 0, 255])
        let request = Data(#"{"provider":"codex","selection":{"kind":"codex","email":"person@example.com"}}"#.utf8)
        let archive = try RemoteAccountSyncTransport.archive(helperData: helper, requestData: request)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-account-sync-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let archiveURL = root.appendingPathComponent("payload.tar")
        try archive.write(to: archiveURL)
        let extractURL = root.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractURL, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", archiveURL.path, "-C", extractURL.path]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(try Data(contentsOf: extractURL.appendingPathComponent("CodexBarCLI")) == helper)
        #expect(try Data(contentsOf: extractURL.appendingPathComponent("request.json")) == request)
    }

    @Test
    func `temporary probe executes helper and cleans its remote directory`() throws {
        let helper = Data(
            "#!/bin/sh\nprintf '%s\\n' '{\"schemaVersion\":1,\"accountSyncSchemaVersion\":1}'\n".utf8)
        let archive = try RemoteAccountSyncTransport.archive(helperData: helper, requestData: nil)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-account-sync-shell-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let archiveURL = root.appendingPathComponent("payload.tar")
        try archive.write(to: archiveURL)
        let inputFile = try FileHandle(forReadingFrom: archiveURL)
        defer { inputFile.closeFile() }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RemoteAccountSyncTransport.remoteCommand(probe: true)]
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = root.path
        environment["HOME"] = root.path
        process.environment = environment
        process.standardInput = inputFile
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .contains("accountSyncSchemaVersion"))
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .allSatisfy { !$0.lastPathComponent.hasPrefix("codexbar-account-sync.") })
    }
}
