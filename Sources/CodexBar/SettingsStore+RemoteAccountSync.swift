import CodexBarCore
import Foundation

extension SettingsStore {
    var remoteAccountSyncHostList: [String] {
        var seen: Set<String> = []
        return self.remoteAccountSyncHosts
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func setRemoteAccountSyncHost(_ host: String, selected: Bool) {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        var hosts = self.remoteAccountSyncHostList
        if selected {
            guard !hosts.contains(normalized) else { return }
            hosts.append(normalized)
        } else {
            hosts.removeAll { $0 == normalized }
        }
        self.remoteAccountSyncHosts = hosts.joined(separator: ", ")
    }

    @discardableResult
    func addRemoteAccountSyncHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              (try? RemoteAccountSynchronizer.validateHost(normalized)) != nil,
              !self.remoteAccountSyncHostList.contains(normalized)
        else { return false }
        self.setRemoteAccountSyncHost(normalized, selected: true)
        return true
    }

    func removeRemoteAccountSyncHost(_ host: String) {
        self.setRemoteAccountSyncHost(host, selected: false)
    }

    func synchronizeRemoteAccount(_ selection: RemoteAccountSyncSelection) async -> [RemoteAccountSyncHostResult] {
        await self.synchronizeRemoteAccount(selection, hosts: nil)
    }

    func synchronizeRemoteAccount(
        _ selection: RemoteAccountSyncSelection,
        hosts requestedHosts: [String]?) async -> [RemoteAccountSyncHostResult]
    {
        guard self.remoteAccountSyncEnabled else { return [] }
        let configuredHosts = self.remoteAccountSyncHostList
        let hosts = if let requestedHosts {
            requestedHosts.filter { configuredHosts.contains($0) }
        } else {
            configuredHosts
        }
        guard !hosts.isEmpty else { return [] }
        let request = RemoteAccountSyncRequest(
            provider: self.remoteProvider(for: selection),
            selection: selection)
        return await RemoteAccountSynchronizer().synchronize(hosts: hosts, request: request)
    }

    func enqueueRemoteAccountSync(_ selection: RemoteAccountSyncSelection) {
        guard self.remoteAccountSyncEnabled, !self.remoteAccountSyncHostList.isEmpty else { return }
        let previousTask = self.remoteAccountSyncTask
        self.remoteAccountSyncTask = Task { @MainActor [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard let self else { return }
            let results = await self.synchronizeRemoteAccount(selection)
            let failedHosts = results.filter { !$0.succeeded }.map(\.host)
            guard !failedHosts.isEmpty else { return }
            CodexBarLog.logger(LogCategories.settings).warning(
                "Remote account sync failed",
                metadata: ["hosts": failedHosts.joined(separator: ",")])
        }
    }

    private func remoteProvider(for selection: RemoteAccountSyncSelection) -> String {
        switch selection {
        case .codex:
            "codex"
        case .tokenAccount:
            // The token-account caller supplies the provider through the overload below.
            ""
        case .claudeSwap:
            "claude"
        }
    }

    func synchronizeRemoteTokenAccount(
        provider: UsageProvider,
        account: ProviderTokenAccount) async -> [RemoteAccountSyncHostResult]
    {
        guard self.remoteAccountSyncEnabled else { return [] }
        let selection = RemoteAccountSyncSelection.tokenAccount(
            externalIdentifier: account.externalIdentifier,
            label: account.label)
        let hosts = self.remoteAccountSyncHostList
        guard !hosts.isEmpty else { return [] }
        let request = RemoteAccountSyncRequest(provider: provider.rawValue, selection: selection)
        return await RemoteAccountSynchronizer().synchronize(hosts: hosts, request: request)
    }

    func enqueueRemoteTokenAccountSync(provider: UsageProvider, account: ProviderTokenAccount) {
        guard self.remoteAccountSyncEnabled, !self.remoteAccountSyncHostList.isEmpty else { return }
        let previousTask = self.remoteAccountSyncTask
        self.remoteAccountSyncTask = Task { @MainActor [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard let self else { return }
            let results = await self.synchronizeRemoteTokenAccount(provider: provider, account: account)
            let failedHosts = results.filter { !$0.succeeded }.map(\.host)
            guard !failedHosts.isEmpty else { return }
            CodexBarLog.logger(LogCategories.settings).warning(
                "Remote account sync failed",
                metadata: [
                    "provider": provider.rawValue,
                    "hosts": failedHosts.joined(separator: ","),
                ])
        }
    }
}
