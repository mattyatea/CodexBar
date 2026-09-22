import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runRemoteAccountSync(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        if values.flags.contains("probe") {
            guard !values.flags.contains("stdin") else {
                Self.exit(
                    code: .failure,
                    message: "account-sync --probe cannot be combined with --stdin.",
                    output: output,
                    kind: .args)
            }
            let response = RemoteAccountSyncProbeResponse(cliVersion: Self.currentVersion())
            if values.flags.contains("json") {
                Self.printJSON(response, pretty: false)
            } else {
                let version = response.cliVersion.map { "CodexBar \($0)" } ?? "CodexBar"
                print("\(version) account-sync v\(response.accountSyncSchemaVersion)")
            }
            Self.exit(code: .success, output: output, kind: .runtime)
        }

        guard values.flags.contains("stdin") else {
            Self.exit(
                code: .failure,
                message: "account-sync requires --stdin.",
                output: output,
                kind: .args)
        }

        let requestData = FileHandle.standardInput.readDataToEndOfFile()
        guard requestData.count <= RemoteAccountSynchronizer.maximumRequestBytes else {
            Self.exit(
                code: .failure,
                message: "The account sync request is too large.",
                output: output,
                kind: .args)
        }

        let request: RemoteAccountSyncRequest
        do {
            request = try JSONDecoder().decode(RemoteAccountSyncRequest.self, from: requestData)
        } catch {
            Self.exit(
                code: .failure,
                message: RemoteAccountSyncApplyError.invalidRequest.localizedDescription,
                output: output,
                kind: .args)
        }

        do {
            let response = try await RemoteAccountSyncReceiver.apply(request)
            if values.flags.contains("json") {
                Self.printJSON(response, pretty: false)
            } else {
                print(response.detail)
            }
            Self.exit(code: .success, output: output, kind: .runtime)
        } catch {
            Self.exit(
                code: .failure,
                message: error.localizedDescription,
                output: output,
                kind: .provider)
        }
    }
}
