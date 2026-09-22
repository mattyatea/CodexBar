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
    func `ssh arguments are non interactive and use fixed receiver command`() throws {
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
        let expectedCommand = "'if command -v codexbar >/dev/null 2>&1; then exec codexbar account-sync --stdin --json; "
            + "else exec /Applications/CodexBar.app/Contents/Helpers/CodexBarCLI account-sync --stdin --json; fi'"
        #expect(arguments.last == expectedCommand)
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
    func `connectivity arguments are read only and use the version probe`() throws {
        let arguments = try RemoteAccountConnectivityTester.arguments(host: "builder@example.com")

        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("StrictHostKeyChecking=yes"))
        #expect(arguments.contains("RemoteCommand=none"))
        #expect(arguments.contains("ConnectTimeout=5") == false)
        #expect(arguments.contains("ForwardAgent=no"))
        #expect(arguments.contains("ClearAllForwardings=yes"))
        #expect(arguments.contains("-T"))
        #expect(arguments.contains("-n"))
        let remoteCommand = arguments.last ?? ""
        #expect(remoteCommand.contains("--stdin") == false)
        #expect(remoteCommand.contains("account-sync --probe --json"))
        let expectedCommand = "'if command -v codexbar >/dev/null 2>&1; then exec codexbar account-sync --probe --json; "
            + "else if [ -x /Applications/CodexBar.app/Contents/Helpers/CodexBarCLI ]; then "
            + "exec /Applications/CodexBar.app/Contents/Helpers/CodexBarCLI account-sync --probe --json; "
            + "else echo CodexBar CLI not found >&2; exit 127; fi; fi'"
        #expect(arguments.last == expectedCommand)
    }

    @Test
    func `connectivity check reports remote CLI output`() async {
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
}
