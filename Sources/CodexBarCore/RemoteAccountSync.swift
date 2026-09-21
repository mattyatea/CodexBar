import Foundation

/// A provider-neutral, credential-free account selection that can be sent to a
/// CodexBar CLI on an SSH host.
///
/// The selection identifies an account that should already exist on the remote
/// host. It deliberately does not contain API keys, cookies, auth files, or
/// other credential material.
public enum RemoteAccountSyncSelection: Codable, Equatable, Sendable {
    case codex(email: String, workspaceAccountID: String?)
    case tokenAccount(externalIdentifier: String?, label: String?)
    case claudeSwap(slot: Int, email: String?)

    private enum Kind: String, Codable {
        case codex
        case tokenAccount
        case claudeSwap
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case email
        case workspaceAccountID
        case externalIdentifier
        case label
        case slot
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .codex:
            self = try .codex(
                email: container.decode(String.self, forKey: .email),
                workspaceAccountID: container.decodeIfPresent(String.self, forKey: .workspaceAccountID))
        case .tokenAccount:
            self = try .tokenAccount(
                externalIdentifier: container.decodeIfPresent(String.self, forKey: .externalIdentifier),
                label: container.decodeIfPresent(String.self, forKey: .label))
        case .claudeSwap:
            self = try .claudeSwap(
                slot: container.decode(Int.self, forKey: .slot),
                email: container.decodeIfPresent(String.self, forKey: .email))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .codex(email, workspaceAccountID):
            try container.encode(Kind.codex, forKey: .kind)
            try container.encode(email, forKey: .email)
            try container.encodeIfPresent(workspaceAccountID, forKey: .workspaceAccountID)
        case let .tokenAccount(externalIdentifier, label):
            try container.encode(Kind.tokenAccount, forKey: .kind)
            try container.encodeIfPresent(externalIdentifier, forKey: .externalIdentifier)
            try container.encodeIfPresent(label, forKey: .label)
        case let .claudeSwap(slot, email):
            try container.encode(Kind.claudeSwap, forKey: .kind)
            try container.encode(slot, forKey: .slot)
            try container.encodeIfPresent(email, forKey: .email)
        }
    }
}

public struct RemoteAccountSyncRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let provider: String
    public let selection: RemoteAccountSyncSelection

    public init(
        provider: String,
        selection: RemoteAccountSyncSelection,
        schemaVersion: Int = RemoteAccountSyncRequest.currentSchemaVersion)
    {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.selection = selection
    }
}

public struct RemoteAccountSyncResponse: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let status: String
    public let provider: String
    public let detail: String

    public init(
        status: String,
        provider: String,
        detail: String,
        schemaVersion: Int = RemoteAccountSyncResponse.currentSchemaVersion)
    {
        self.schemaVersion = schemaVersion
        self.status = status
        self.provider = provider
        self.detail = detail
    }
}

public struct RemoteAccountSyncHostResult: Equatable, Sendable {
    public let host: String
    public let succeeded: Bool
    public let errorDescription: String?

    public init(host: String, succeeded: Bool, errorDescription: String? = nil) {
        self.host = host
        self.succeeded = succeeded
        self.errorDescription = errorDescription
    }
}

public enum RemoteAccountSyncError: LocalizedError, Equatable, Sendable {
    case invalidHost
    case invalidRequest
    case unavailable
    case invalidResponse
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHost:
            "Enter a valid SSH host alias or user@host."
        case .invalidRequest:
            "The remote account sync request is invalid or unsupported."
        case .unavailable:
            "SSH is unavailable on this Mac."
        case .invalidResponse:
            "The remote CodexBar CLI returned an unsupported account sync response."
        case let .commandFailed(message):
            "Remote account sync failed: \(message)"
        }
    }
}

/// Sends account selections to configured SSH hosts without putting secrets in
/// command-line arguments. The receiving host must have a CodexBar CLI that
/// supports `account-sync --stdin --json`.
public struct RemoteAccountSynchronizer: Sendable {
    public typealias Runner = @Sendable (
        _ arguments: [String],
        _ environment: [String: String],
        _ standardInput: Data) async throws -> String

    public static let maximumOutputBytes = 16 * 1024
    public static let maximumRequestBytes = 64 * 1024

    private let runner: Runner

    public init() {
        self.runner = { arguments, environment, requestData in
            let binary = ["/usr/bin/ssh", "/bin/ssh"].first {
                FileManager.default.isExecutableFile(atPath: $0)
            }
            guard let binary else { throw RemoteAccountSyncError.unavailable }

            let inputPipe = Pipe()
            inputPipe.fileHandleForWriting.write(requestData)
            inputPipe.fileHandleForWriting.closeFile()
            let result = try await SubprocessRunner.run(
                binary: binary,
                arguments: arguments,
                environment: environment,
                timeout: 60,
                maxOutputBytes: Self.maximumOutputBytes,
                standardInput: inputPipe,
                label: "sync remote provider account")
            return result.stdout
        }
    }

    public init(runner: @escaping Runner) {
        self.runner = runner
    }

    public static func validateHost(_ host: String) throws {
        let allowed =
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:%[]")
        guard !host.isEmpty, !host.hasPrefix("-"), host.utf8.count <= 255,
              host.unicodeScalars.allSatisfy(allowed.contains)
        else { throw RemoteAccountSyncError.invalidHost }
    }

    public static func arguments(host: String) throws -> [String] {
        try self.validateHost(host)
        let command = "if command -v codexbar >/dev/null 2>&1; then exec codexbar account-sync --stdin --json; " +
            "else exec /Applications/CodexBar.app/Contents/Helpers/CodexBarCLI account-sync --stdin --json; fi"
        return [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "RemoteCommand=none",
            "-o", "RequestTTY=no",
            "-o", "ForwardAgent=no",
            "-o", "ClearAllForwardings=yes",
            "-T", "--", host,
            "sh", "-lc", "'\(command)'",
        ]
    }

    public func synchronize(
        hosts: [String],
        request: RemoteAccountSyncRequest,
        environment: [String: String] = ProcessInfo.processInfo.environment) async -> [RemoteAccountSyncHostResult]
    {
        let normalizedHosts = Self.uniqueHosts(hosts)
        guard !normalizedHosts.isEmpty else { return [] }

        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(request)
        } catch {
            return normalizedHosts.map {
                RemoteAccountSyncHostResult(
                    host: $0,
                    succeeded: false,
                    errorDescription: RemoteAccountSyncError.invalidRequest.localizedDescription)
            }
        }
        guard requestData.count <= Self.maximumRequestBytes else {
            return normalizedHosts.map {
                RemoteAccountSyncHostResult(
                    host: $0,
                    succeeded: false,
                    errorDescription: "The account sync request is too large.")
            }
        }

        let allowedEnvironment = Set(["PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "SSH_AUTH_SOCK"])
        let filteredEnvironment = environment.filter { allowedEnvironment.contains($0.key) }
        return await withTaskGroup(
            of: RemoteAccountSyncHostResult.self,
            returning: [RemoteAccountSyncHostResult].self)
        {
            group in
            for host in normalizedHosts {
                group.addTask {
                    do {
                        let arguments = try Self.arguments(host: host)
                        let output = try await self.runner(arguments, filteredEnvironment, requestData)
                        let response = try JSONDecoder().decode(
                            RemoteAccountSyncResponse.self,
                            from: Data(output.utf8))
                        guard response.schemaVersion == RemoteAccountSyncResponse.currentSchemaVersion,
                              response.provider == request.provider,
                              response.status == "applied" || response.status == "noop"
                        else {
                            throw RemoteAccountSyncError.invalidResponse
                        }
                        return RemoteAccountSyncHostResult(host: host, succeeded: true)
                    } catch is CancellationError {
                        return RemoteAccountSyncHostResult(
                            host: host,
                            succeeded: false,
                            errorDescription: "Cancelled")
                    } catch {
                        let description = Self.safeErrorDescription(error)
                        return RemoteAccountSyncHostResult(
                            host: host,
                            succeeded: false,
                            errorDescription: description)
                    }
                }
            }

            var results: [RemoteAccountSyncHostResult] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
        }
    }

    private static func uniqueHosts(_ hosts: [String]) -> [String] {
        var seen: Set<String> = []
        return hosts.compactMap { raw in
            let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, seen.insert(host).inserted else { return nil }
            return host
        }
    }

    private static func safeErrorDescription(_ error: Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let singleLine = raw
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(300))
    }
}

public enum RemoteAccountSyncApplyError: LocalizedError, Equatable, Sendable {
    case invalidRequest
    case unsupportedProvider
    case accountNotFound
    case accountAmbiguous
    case credentialUnavailable
    case apiKeyAccountUnsupported
    case workspaceAccountMismatch
    case configUnavailable
    case executableUnavailable
    case externalSwitchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "The remote account sync request is invalid."
        case .unsupportedProvider:
            "The provider or account selection is not supported on this host."
        case .accountNotFound:
            "The requested account is not configured on this host."
        case .accountAmbiguous:
            "More than one configured account matches the remote account selection."
        case .credentialUnavailable:
            "The requested Codex account has no usable credentials on this host."
        case .apiKeyAccountUnsupported:
            "API-key-only Codex accounts cannot be selected as a system account."
        case .workspaceAccountMismatch:
            "The requested Codex workspace does not match the account auth file."
        case .configUnavailable:
            "CodexBar configuration could not be read or saved on this host."
        case .executableUnavailable:
            "The configured claude-swap executable is unavailable on this host."
        case let .externalSwitchFailed(message):
            "The provider account switch failed: \(message)"
        }
    }
}

/// Applies a request on the receiving host. This is intentionally kept in the
/// core target so the same implementation is available to macOS and Linux CLI
/// installations.
public enum RemoteAccountSyncReceiver {
    public static func apply(
        _ request: RemoteAccountSyncRequest,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws
        -> RemoteAccountSyncResponse
    {
        guard request.schemaVersion == RemoteAccountSyncRequest.currentSchemaVersion,
              let provider = UsageProvider(rawValue: request.provider)
        else { throw RemoteAccountSyncApplyError.invalidRequest }

        switch request.selection {
        case let .codex(email, workspaceAccountID):
            guard provider == .codex else { throw RemoteAccountSyncApplyError.invalidRequest }
            try self.applyCodex(
                email: email,
                workspaceAccountID: workspaceAccountID,
                environment: environment)
            return RemoteAccountSyncResponse(
                status: "applied",
                provider: provider.rawValue,
                detail: "Codex system account selected")
        case let .tokenAccount(externalIdentifier, label):
            try self.applyTokenAccount(
                provider: provider,
                externalIdentifier: externalIdentifier,
                label: label,
                environment: environment)
            return RemoteAccountSyncResponse(
                status: "applied",
                provider: provider.rawValue,
                detail: "Provider token account selected")
        case let .claudeSwap(slot, email):
            guard provider == .claude, slot > 0 else { throw RemoteAccountSyncApplyError.invalidRequest }
            try await self.applyClaudeSwap(slot: slot, email: email, environment: environment)
            return RemoteAccountSyncResponse(
                status: "applied",
                provider: provider.rawValue,
                detail: "Claude account selected")
        }
    }

    private static func applyCodex(
        email: String,
        workspaceAccountID: String?,
        environment: [String: String]) throws
    {
        let accounts: ManagedCodexAccountSet
        do {
            accounts = try FileManagedCodexAccountStore().loadAccounts()
        } catch {
            throw RemoteAccountSyncApplyError.accountNotFound
        }
        let normalizedEmail = ManagedCodexAccount.normalizeEmail(email)
        let emailMatches = accounts.accounts.filter { $0.email == normalizedEmail }
        let account: ManagedCodexAccount
        if let workspaceAccountID = ManagedCodexAccount.normalizeWorkspaceAccountID(workspaceAccountID) {
            let workspaceMatches = emailMatches.filter {
                $0.effectiveWorkspaceAccountID == workspaceAccountID
            }
            if workspaceMatches.count == 1, let match = workspaceMatches.first {
                account = match
            } else if workspaceMatches.isEmpty {
                let legacyMatches = emailMatches.filter { $0.effectiveWorkspaceAccountID == nil }
                if legacyMatches.count == 1, let match = legacyMatches.first {
                    account = match
                } else if legacyMatches.isEmpty {
                    throw emailMatches.isEmpty
                        ? RemoteAccountSyncApplyError.accountNotFound
                        : RemoteAccountSyncApplyError.accountAmbiguous
                } else {
                    throw RemoteAccountSyncApplyError.accountAmbiguous
                }
            } else {
                throw RemoteAccountSyncApplyError.accountAmbiguous
            }
        } else if emailMatches.count == 1, let match = emailMatches.first {
            account = match
        } else if emailMatches.isEmpty {
            throw RemoteAccountSyncApplyError.accountNotFound
        } else {
            throw RemoteAccountSyncApplyError.accountAmbiguous
        }

        let managedAuthURL = CodexAuthFingerprint.authFileURL(homePath: account.managedHomePath)
        let rawData: Data
        let credentials: CodexOAuthCredentials
        do {
            rawData = try CodexCredentialFileAccess.read(at: managedAuthURL)
            credentials = try CodexOAuthCredentialsStore.parse(data: rawData)
        } catch {
            throw RemoteAccountSyncApplyError.credentialUnavailable
        }
        guard !credentials.isAPIKey else { throw RemoteAccountSyncApplyError.apiKeyAccountUnsupported }
        if let workspaceAccountID = account.effectiveWorkspaceAccountID,
           let authAccountID = ManagedCodexAccount.normalizeWorkspaceAccountID(credentials.accountId),
           workspaceAccountID != authAccountID
        {
            throw RemoteAccountSyncApplyError.workspaceAccountMismatch
        }
        if let expectedFingerprint = account.authFingerprint,
           CodexAuthFingerprint.fingerprint(data: rawData) != expectedFingerprint
        {
            throw RemoteAccountSyncApplyError.credentialUnavailable
        }

        let liveAuthURL = CodexAuthFingerprint.authFileURL(
            homePath: CodexHomeScope.ambientHomeURL(env: environment).path)
        do {
            guard CodexCredentialFileAccess.permits(liveAuthURL) else {
                throw CodexOAuthCredentialsError.notFound
            }
            try CodexCredentialFileAccess.createDirectory(forCredentialAt: liveAuthURL)
            try CredentialFileWriter.writePrivate(rawData, to: liveAuthURL)
        } catch {
            throw RemoteAccountSyncApplyError.credentialUnavailable
        }

        var config: CodexBarConfig
        let store = CodexBarConfigStore(fileURL: CodexBarConfigStore.defaultURL(environment: environment))
        do {
            config = try store.loadOrCreateDefault()
        } catch {
            throw RemoteAccountSyncApplyError.configUnavailable
        }
        var providerConfig = config.providerConfig(for: UsageProvider.codex.instanceID)
            ?? ProviderConfig(id: UsageProvider.codex.instanceID)
        providerConfig.codexActiveSource = .liveSystem
        config.setProviderConfig(providerConfig)
        do {
            try store.save(config)
        } catch {
            throw RemoteAccountSyncApplyError.configUnavailable
        }
    }

    private static func applyTokenAccount(
        provider: UsageProvider,
        externalIdentifier: String?,
        label: String?,
        environment: [String: String]) throws
    {
        let store = CodexBarConfigStore(fileURL: CodexBarConfigStore.defaultURL(environment: environment))
        var config: CodexBarConfig
        do {
            config = try store.loadOrCreateDefault()
        } catch {
            throw RemoteAccountSyncApplyError.configUnavailable
        }
        guard var providerConfig = config.providerConfig(for: provider.instanceID),
              let accountData = providerConfig.tokenAccounts
        else { throw RemoteAccountSyncApplyError.accountNotFound }

        let normalizedExternalIdentifier = self.normalized(externalIdentifier)
        let normalizedLabel = self.normalized(label)
        let matchingIndices = accountData.accounts.indices.filter { index in
            let account = accountData.accounts[index]
            if let normalizedExternalIdentifier,
               self.normalized(account.externalIdentifier) == normalizedExternalIdentifier
            {
                return true
            }
            return normalizedExternalIdentifier == nil &&
                normalizedLabel != nil &&
                self.normalized(account.label) == normalizedLabel
        }
        guard matchingIndices.count == 1, let matchingIndex = matchingIndices.first else {
            throw matchingIndices.isEmpty
                ? RemoteAccountSyncApplyError.accountNotFound
                : RemoteAccountSyncApplyError.accountAmbiguous
        }

        providerConfig.tokenAccounts = ProviderTokenAccountData(
            version: accountData.version,
            accounts: accountData.accounts,
            activeIndex: matchingIndex)
        config.setProviderConfig(providerConfig)
        do {
            try store.save(config)
        } catch {
            throw RemoteAccountSyncApplyError.configUnavailable
        }
    }

    private static func applyClaudeSwap(
        slot: Int,
        email: String?,
        environment: [String: String]) async throws
    {
        let store = CodexBarConfigStore(fileURL: CodexBarConfigStore.defaultURL(environment: environment))
        let config: CodexBarConfig?
        do {
            config = try store.load()
        } catch {
            throw RemoteAccountSyncApplyError.configUnavailable
        }
        guard let path = config?.providerConfig(for: .claude)?.sanitizedClaudeSwapExecutablePath,
              !path.isEmpty
        else { throw RemoteAccountSyncApplyError.executableUnavailable }

        let accountNumber: Int
        if let normalizedEmail = self.normalized(email) {
            let accountList: ClaudeSwapAccountList
            do {
                accountList = try await ClaudeSwapAccountReader.readAccountList(executablePath: path)
            } catch {
                throw RemoteAccountSyncApplyError.accountNotFound
            }
            let matches = accountList.accounts.filter { self.normalized($0.email) == normalizedEmail }
            guard matches.count == 1, let match = matches.first else {
                throw RemoteAccountSyncApplyError.accountNotFound
            }
            accountNumber = match.number
        } else {
            accountNumber = slot
        }

        do {
            _ = try await ClaudeSwapAccountReader.switchAccount(
                executablePath: path,
                accountNumber: accountNumber)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw RemoteAccountSyncApplyError.externalSwitchFailed(String(message.prefix(300)))
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }
}
