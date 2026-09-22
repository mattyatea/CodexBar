import CodexBarCore
import SwiftUI

@MainActor
struct MenuPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    var body: some View {
        Form {
            Section {
                SettingsMenuPicker(
                    selection: self.$settings.usageBarsFillOption,
                    options: MenuSettingsMenuOptions.usageBarsFill,
                    label: { Text(L("usage_bars_fill_title")) },
                    optionLabel: { option in
                        Text(option.label)
                    })

                Toggle(isOn: self.$settings.quotaWarningMarkersVisible) {
                    SettingsRowLabel(
                        L("show_quota_warning_markers_title"),
                        subtitle: L("show_quota_warning_markers_subtitle"))
                }

                Toggle(isOn: self.$settings.paceVisible) {
                    SettingsRowLabel(
                        L("show_pace_title"),
                        subtitle: L("show_pace_subtitle"))
                }

                SettingsMenuPicker(
                    selection: self.$settings.weeklyProgressWorkDays,
                    options: MenuSettingsMenuOptions.weeklyProgressWorkDays,
                    label: {
                        Text(L("weekly_progress_work_days_title"))
                    },
                    optionLabel: { workDays in
                        Text(MenuSettingsMenuOptions.weeklyProgressWorkDaysLabel(workDays))
                    })

                SettingsMenuPicker(
                    selection: self.$settings.workdayTickAppearance,
                    options: MenuSettingsMenuOptions.workdayTickAppearances,
                    label: {
                        SettingsRowLabel(
                            L("workday_tick_appearance_title"),
                            subtitle: L("workday_tick_appearance_subtitle"))
                    },
                    optionLabel: { appearance in
                        Text(appearance.label)
                    })
                    .disabled(self.settings.weeklyProgressWorkDays == nil)

                SettingsMenuPicker(
                    selection: self.$settings.resetTimesOption,
                    options: MenuSettingsMenuOptions.resetTimes,
                    label: { Text(L("reset_times_title")) },
                    optionLabel: { option in
                        Text(option.label)
                    })
            } header: {
                Text(L("section_usage"))
            }

            Section {
                Toggle(L("show_provider_changelog_links_title"), isOn: self.$settings.providerChangelogLinksEnabled)

                SettingsMenuPicker(
                    selection: self.$settings.mergedOverviewLayout,
                    options: MenuSettingsMenuOptions.mergedOverviewLayouts,
                    label: {
                        SettingsRowLabel(L("overview_layout_title"), subtitle: L("overview_layout_subtitle"))
                    },
                    optionLabel: { Text($0.label) })
                    .disabled(!self.settings.mergeIcons)

                Toggle(isOn: self.$settings.showOptionalCreditsAndExtraUsage) {
                    SettingsRowLabel(
                        L("show_credits_extra_usage_title"),
                        subtitle: L("show_credits_extra_usage_subtitle"))
                }

                SettingsMenuPicker(
                    selection: self.$settings.multiAccountMenuLayout,
                    options: MenuSettingsMenuOptions.multiAccountLayouts,
                    label: {
                        Text(L("multi_account_layout_title"))
                    },
                    optionLabel: { layout in
                        Text(layout.label)
                    })
            } header: {
                Text(L("section_content"))
            }

            Section(L("section_widgets")) {
                Toggle(isOn: self.$settings.accountWidgetsEnabled) {
                    SettingsRowLabel(
                        L("account_widgets_title"),
                        subtitle: L("account_widgets_description"))
                }
                .onChange(of: self.settings.accountWidgetsEnabled) { _, enabled in
                    self.store.persistWidgetSnapshot(reason: "account-widgets-setting")
                    if enabled {
                        Task { await self.store.refresh() }
                    }
                }
            }

            CostSummarySettingsSection(settings: self.settings, store: self.store)

            AgentSessionsSettingsSection(settings: self.settings)
            RemoteAccountSyncSettingsSection(settings: self.settings)
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .background(FocusResigningBackground())
    }
}

@MainActor
struct RemoteAccountSyncSettingsSection: View {
    @Bindable var settings: SettingsStore
    @State private var discoveredSSHHosts: [RemoteSSHHost] = []
    @State private var isLoadingSSHConfig = false
    @State private var sshConfigError: String?
    @State private var manualHost = ""
    @State private var manualHostError: String?
    @State private var connectivityResults: [String: RemoteAccountConnectivityResult] = [:]
    @State private var testingHosts: Set<String> = []

    var body: some View {
        Section {
            Toggle(isOn: self.$settings.remoteAccountSyncEnabled) {
                SettingsRowLabel(
                    L("remote_account_sync_title"),
                    subtitle: L("remote_account_sync_subtitle"))
            }

            if self.settings.remoteAccountSyncEnabled {
                self.hostSelection
            }
        } header: {
            Text(L("remote_account_sync_title"))
        } footer: {
            SettingsSectionFooter(L("remote_account_sync_footer"))
        }
        .task(id: self.settings.remoteAccountSyncEnabled) {
            guard self.settings.remoteAccountSyncEnabled else { return }
            self.reloadSSHConfig()
        }
    }

    @ViewBuilder
    private var hostSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("remote_account_sync_config_hosts_title"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    self.testSelectedSSHHosts()
                } label: {
                    if self.testingHosts.isEmpty {
                        Label(L("remote_account_sync_test_selected"), systemImage: "network")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(
                    self.settings.remoteAccountSyncHostList.isEmpty || !self.testingHosts.isEmpty)
                .help(L("remote_account_sync_test_help"))
                Button {
                    self.reloadSSHConfig()
                } label: {
                    if self.isLoadingSSHConfig {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(L("Refresh"), systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(self.isLoadingSSHConfig)
                .help(L("remote_account_sync_refresh_config_help"))
            }

            if self.isLoadingSSHConfig, self.discoveredSSHHosts.isEmpty {
                ProgressView(L("remote_account_sync_loading_config"))
                    .controlSize(.small)
            } else if self.discoveredSSHHosts.isEmpty {
                Text(self.sshConfigError ?? L("remote_account_sync_no_config_hosts"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(self.discoveredSSHHosts) { host in
                    self.configHostRow(host)
                }
            }
        }

        if !self.manualHosts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("remote_account_sync_manual_hosts_title"))
                    .font(.subheadline.weight(.semibold))
                ForEach(self.manualHosts, id: \.self) { host in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                        Text(host)
                            .textSelection(.enabled)
                        Spacer()
                        self.connectivityStatus(for: host)
                        self.testButton(for: host)
                        Button(L("remove"), role: .destructive) {
                            self.settings.removeRemoteAccountSyncHost(host)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }

        VStack(alignment: .leading, spacing: 5) {
            Text(L("remote_account_sync_manual_add_title"))
                .font(.subheadline.weight(.semibold))
            HStack {
                TextField(
                    L("remote_account_sync_manual_host_placeholder"),
                    text: self.$manualHost,
                    prompt: Text(verbatim: "alias or user@host"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { self.addManualHost() }
                Button(L("Add")) { self.addManualHost() }
                    .disabled(self.manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let manualHostError = self.manualHostError {
                Text(manualHostError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .disabled(!self.settings.remoteAccountSyncEnabled)
    }

    private func configHostRow(_ host: RemoteSSHHost) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: self.hostSelectionBinding(for: host.alias)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.displayName)
                    if let detail = self.hostDetail(host), !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 4)
            self.connectivityStatus(for: host.alias)
            self.testButton(for: host.alias)
        }
    }

    private var manualHosts: [String] {
        let discovered = Set(self.discoveredSSHHosts.map(\.alias))
        return self.settings.remoteAccountSyncHostList.filter { !discovered.contains($0) }
    }

    private func hostSelectionBinding(for alias: String) -> Binding<Bool> {
        Binding(
            get: { self.settings.remoteAccountSyncHostList.contains(alias) },
            set: { self.settings.setRemoteAccountSyncHost(alias, selected: $0) })
    }

    private func hostDetail(_ host: RemoteSSHHost) -> String? {
        var values: [String] = []
        if let user = host.user { values.append(user) }
        if let hostname = host.hostname { values.append(hostname) }
        if let port = host.port { values.append("port \(port)") }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    @ViewBuilder
    private func connectivityStatus(for host: String) -> some View {
        if self.testingHosts.contains(host) {
            ProgressView()
                .controlSize(.small)
        } else if let result = self.connectivityResults[host] {
            VStack(alignment: .leading, spacing: 1) {
                Label(
                    result.succeeded
                        ? (result.detail ?? L("remote_account_sync_test_succeeded"))
                        : L("remote_account_sync_test_failed"),
                    systemImage: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(result.succeeded ? .green : .red)
                    .lineLimit(1)
                if let errorDescription = result.errorDescription {
                    Text(errorDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(errorDescription)
                }
            }
        }
    }

    private func testButton(for host: String) -> some View {
        Button {
            self.testRemoteHosts([host])
        } label: {
            Image(systemName: "network")
        }
        .buttonStyle(.borderless)
        .disabled(self.testingHosts.contains(host))
        .help(L("remote_account_sync_test_host"))
    }

    private func testSelectedSSHHosts() {
        self.testRemoteHosts(self.settings.remoteAccountSyncHostList)
    }

    private func testRemoteHosts(_ hosts: [String]) {
        let hosts = Array(Set(hosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
            .sorted()
        guard !hosts.isEmpty else { return }

        self.testingHosts.formUnion(hosts)
        for host in hosts {
            self.connectivityResults[host] = nil
        }

        Task { @MainActor in
            let results = await RemoteAccountConnectivityTester().check(hosts: hosts)
            for result in results {
                self.connectivityResults[result.host] = result
                self.testingHosts.remove(result.host)
            }
            self.testingHosts.subtract(hosts)
        }
    }

    private func reloadSSHConfig() {
        guard !self.isLoadingSSHConfig else { return }
        self.isLoadingSSHConfig = true
        self.sshConfigError = nil
        defer { self.isLoadingSSHConfig = false }
        do {
            self.discoveredSSHHosts = try RemoteSSHConfig.hosts()
        } catch {
            self.discoveredSSHHosts = []
            self.sshConfigError = L("remote_account_sync_config_read_failed")
        }
    }

    private func addManualHost() {
        let candidate = self.manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        guard self.settings.addRemoteAccountSyncHost(candidate) else {
            self.manualHostError = L("remote_account_sync_invalid_host")
            return
        }
        self.manualHost = ""
        self.manualHostError = nil
    }
}

@MainActor
struct AgentSessionsSettingsSection: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Section {
            Toggle(isOn: self.$settings.agentSessionsEnabled) {
                SettingsRowLabel(
                    L("agent_sessions_title"),
                    subtitle: L("agent_sessions_subtitle"))
            }

            SettingsMenuPicker(
                selection: self.$settings.agentSessionLabelStyle,
                options: MenuSettingsMenuOptions.agentSessionLabelStyles,
                label: {
                    SettingsRowLabel(
                        L("agent_session_labels_title"),
                        subtitle: L("agent_session_labels_subtitle"))
                },
                optionLabel: { style in
                    Text(style.label)
                })
                .disabled(!self.settings.agentSessionsEnabled)

            Toggle(isOn: self.$settings.agentSessionsHideUnreachableHosts) {
                SettingsRowLabel(
                    L("agent_sessions_hide_unreachable_title"),
                    subtitle: L("agent_sessions_hide_unreachable_subtitle"))
            }
            .disabled(!self.settings.agentSessionsEnabled)

            AgentSessionHostsEditor(settings: self.settings)
        } header: {
            Text(L("section_agent_sessions"))
        } footer: {
            SettingsSectionFooter(L("agent_sessions_footer"))
        }
    }
}

@MainActor
struct AgentSessionHostsEditor: View {
    static let inputFormatHint = "user@host, user@host"

    @Bindable var settings: SettingsStore

    var body: some View {
        LabeledContent(L("agent_sessions_hosts_title")) {
            TextField(
                L("agent_sessions_hosts_title"),
                text: self.$settings.agentSessionsManualHosts,
                prompt: Text(verbatim: Self.inputFormatHint))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, idealWidth: 280)
                .accessibilityLabel(L("agent_sessions_hosts_title"))
        }
        .disabled(!self.settings.agentSessionsEnabled)
        .help(L("agent_sessions_footer"))
    }
}

/// Cost summary settings grouped-form section, including per-provider fetch status in the footer.
@MainActor
struct CostSummarySettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    var body: some View {
        Section {
            SettingsMenuPicker(
                selection: self.$settings.costSummaryOption,
                options: MenuSettingsMenuOptions.costSummaries,
                label: {
                    SettingsRowLabel(L("cost_summary_title"), subtitle: L("show_cost_summary_subtitle"))
                },
                optionLabel: { option in
                    Text(option.label)
                })

            if self.settings.costUsageEnabled {
                CostHistoryDaysEditor(settings: self.settings)

                Toggle(isOn: self.$settings.costComparisonPeriodsEnabled) {
                    SettingsRowLabel(
                        L("cost_comparison_periods_title"),
                        subtitle: L("cost_comparison_periods_subtitle"))
                }
            }
        } header: {
            Text(L("section_cost_summary"))
        } footer: {
            if self.settings.costUsageEnabled {
                SettingsSectionFooter {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("cost_auto_refresh_info"))
                        ForEach(Self.costStatusProviders, id: \.self) { provider in
                            self.costStatusLine(provider: provider)
                        }
                        Text(Self.costDataExplanation())
                    }
                }
            }
        }
    }

    static func costDataExplanation() -> String {
        L("cost_data_explanation")
    }

    static var costStatusProviders: [UsageProvider] {
        ProviderDescriptorRegistry.all.compactMap { descriptor -> (UsageProvider, Int)? in
            guard let order = descriptor.tokenCost.settingsStatusOrder else { return nil }
            return (descriptor.id, order)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    private func costStatusLine(provider: UsageProvider) -> Text {
        let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName

        guard ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost else {
            return Text(String(format: L("cost_status_unsupported"), name))
        }

        if self.store.isTokenRefreshInFlight(for: provider) {
            let elapsed: String = {
                guard let startedAt = self.store.tokenLastAttemptAt(for: provider) else { return "" }
                let seconds = max(0, Date().timeIntervalSince(startedAt))
                let formatter = DateComponentsFormatter()
                formatter.allowedUnits = seconds < 60 ? [.second] : [.minute, .second]
                formatter.unitsStyle = .abbreviated
                return formatter.string(from: seconds).map { " (\($0))" } ?? ""
            }()
            return Text(String(format: L("cost_status_fetching"), name, elapsed))
        }
        if let snapshot = self.store.tokenSnapshot(for: provider) {
            let updated = UsageFormatter.updatedString(from: snapshot.updatedAt)
            let cost = snapshot.last30DaysCostUSD
                .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
            let window = snapshot.historyLabel ?? (snapshot.historyDays == 1 ? "today" : "\(snapshot.historyDays)d")
            return Text(String(format: L("cost_status_snapshot"), name, updated, window, cost))
        }
        if let error = self.store.tokenError(for: provider), !error.isEmpty {
            let truncated = UsageFormatter.truncatedSingleLine(error, max: 120)
            return Text(String(format: L("cost_status_error"), name, truncated))
        }
        if let lastAttempt = self.store.tokenLastAttemptAt(for: provider) {
            let rel = RelativeDateTimeFormatter()
            rel.locale = Locale(identifier: "en_US")
            rel.unitsStyle = .abbreviated
            let when = rel.localizedString(for: lastAttempt, relativeTo: Date())
            return Text(String(format: L("cost_status_last_attempt"), name, when))
        }
        return Text(String(format: L("cost_status_no_data"), name))
    }
}

@MainActor
struct CostHistoryDaysEditor: View {
    @Bindable var settings: SettingsStore

    static func title(days: Int) -> String {
        String(format: L("cost_history_days_title"), days)
    }

    var body: some View {
        LabeledContent(Self.title(days: self.settings.costUsageHistoryDays)) {
            HStack(spacing: 8) {
                TextField(
                    Self.title(days: self.settings.costUsageHistoryDays),
                    value: self.$settings.costUsageHistoryDays,
                    format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)

                Stepper(value: self.$settings.costUsageHistoryDays, in: 1...365, step: 1) {
                    EmptyView()
                }
                .labelsHidden()
            }
        }
    }
}
