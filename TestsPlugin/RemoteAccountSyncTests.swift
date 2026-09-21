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
        #expect(arguments.contains("ForwardAgent=no"))
        #expect(arguments.contains("ClearAllForwardings=yes"))
        #expect(arguments.contains("-T"))
        #expect(arguments.contains("account-sync"))
        #expect(arguments.contains("--stdin"))
        #expect(arguments.contains("--json"))
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
}
