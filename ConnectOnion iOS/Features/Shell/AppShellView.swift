//
//  AppShellView.swift
//
//  Purpose: Implements AppShellView for the Features/Shell module.
//  Collaborates with: AgentAvatar, AgentListView, AgentSidebarRow, ConnectOnionWordmark, ConversationSidebarRow, EmptyStateHero.
//  References: Apple Swift documentation (https://developer.apple.com/documentation/swift) and
//               the project architecture described in README.md where applicable.
//
//  This file is part of the ConnectOnion iOS application.
//
import SwiftData
import SwiftUI
import UIKit
import WidgetKit

/// Agent-centric navigation levels (P4): the root lists agents, tapping one pushes its home (chat
/// list), and a chat / a fresh-chat landing push on top of that.
enum ShellRoute: Hashable {
    case agentHome(String)   // agent address
    case newChat(String)     // agent address — a fresh landing/composer
    case conversation(UUID)  // conversation id
}

struct AppShellView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \AgentConfigRecord.createdAt) private var agents: [AgentConfigRecord]
    @Query(sort: \ConversationRecord.updatedAt, order: .reverse) private var conversations: [ConversationRecord]

    @State private var path: [ShellRoute] = []
    /// Pairs each agent card with its pushed home for the zoom navigation transition.
    @Namespace private var agentZoomNamespace
    @State private var pendingInputs: [UUID: AgentInput] = [:]
    @State private var agentEditorDraft: AgentEditorDraft?
    @State private var presentedAgentScanner: AgentScannerPresentation?
    @State private var showingSettings = false
    @State private var editingAgent: AgentConfigRecord?
    @State private var deletingAgent: AgentConfigRecord?
    @State private var deletingConversation: ConversationRecord?
    @State private var infoStore = AgentInfoStore()
    // Read the single store RootView owns + injects, so AgentHomeView's @Environment sees the same
    // instance that actually holds the sessions (otherwise the "generating" indicator never fires).
    @Environment(ChatSessionStore.self) private var chatSessionStore
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    var body: some View {
        NavigationStack(path: $path) {
            AgentListView(
                agents: agents,
                infoByAddress: infoStore.infoByAddress,
                zoomNamespace: agentZoomNamespace,
                onSelectAgent: { path.append(.agentHome($0.address)) },
                onAddAgent: { agentEditorDraft = .empty },
                onSettings: { showingSettings = true },
                onRenameAgent: { renameAgentName($0, to: $1) },
                onDeleteAgent: { agent in afterMenuDismiss { deletingAgent = agent } },
                onRefresh: refreshAgentInfo
            )
            .navigationDestination(for: ShellRoute.self) { route in
                destination(for: route)
            }
        }
        // Warm off-black canvas behind the whole stack (the transparent scroll screens show it through),
        // replacing iOS's pure-black dark background.
        .background(Color.appCanvas.ignoresSafeArea())
        .accessibilityIdentifier(AccessibilityID.appShell)
        .sheet(item: $agentEditorDraft) { draft in
            AgentEditorView(
                initialAddress: draft.address,
                initialAlias: draft.alias,
                initialEndpoint: draft.endpoint
            ) { address, alias, endpoint in
                addAgent(address: address, alias: alias, endpoint: endpoint)
            }
        }
        .fullScreenCover(item: $presentedAgentScanner) { _ in
            AgentQRCodeScannerView { payload in
                handleScannedAgent(payload)
            }
        }
        .sheet(item: $editingAgent) { agent in
            AgentEditorView(
                title: "Edit Agent",
                initialAddress: agent.address,
                initialAlias: agent.alias,
                initialEndpoint: agent.preferredEndpoint,
                isAddressEditable: false
            ) { _, alias, endpoint in
                renameAgent(agent, alias: alias, endpoint: endpoint)
            }        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                agents: agents,
                infoByAddress: infoStore.infoByAddress,
                onAddAgent: showAddAgentFromSettings,
                onDeleteAgent: deleteAgent
            )        }
        .confirmationDialog(
            "Delete Agent?",
            isPresented: Binding(
                get: { deletingAgent != nil },
                set: { if !$0 { deletingAgent = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletingAgent
        ) { agent in
            Button("Delete Agent", role: .destructive) {
                deleteAgent(agent)
                deletingAgent = nil
            }
            .accessibilityIdentifier(AccessibilityID.confirmDeleteAgentButton)

            Button("Cancel", role: .cancel) {
                deletingAgent = nil
            }
        }
        .confirmationDialog(
            "Delete Chat?",
            isPresented: Binding(
                get: { deletingConversation != nil },
                set: { if !$0 { deletingConversation = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletingConversation
        ) { conversation in
            Button("Delete Chat", role: .destructive) {
                deleteConversation(conversation)
                deletingConversation = nil
            }
            Button("Cancel", role: .cancel) {
                deletingConversation = nil
            }
        }
        .task {
            applyAppearance(appearance)
            publishWidgetSnapshot()
            configureAgentInfoRefresh()
            chatSessionStore.setAppActive(scenePhase == .active)
        }
        .onChange(of: agents.map(\.address)) { _, addresses in
            publishWidgetSnapshot()
            infoStore.setEndpoints(agentEndpointMap)
            infoStore.startAutoRefresh(addresses: addresses, focusedAddress: focusedAgentAddress)
        }
        .onChange(of: agents.map(\.preferredEndpoint)) { _, _ in
            // Re-probe every agent (not just the focused one) so a just-edited endpoint updates its
            // status immediately instead of waiting for the ~60s all-refresh cycle.
            configureAgentInfoRefresh()
            infoStore.refresh(addresses: agentAddresses)
        }
        .onChange(of: agents.map(\.updatedAt)) { _, _ in
            chatSessionStore.updateAgents(agents.map(\.config))
            publishWidgetSnapshot()
        }
        .onChange(of: conversations.map(\.updatedAt)) { _, _ in
            publishWidgetSnapshot()
        }
        .onChange(of: infoStore.infoByAddress) { _, _ in
            publishWidgetSnapshot()
        }
        .onChange(of: path) { _, _ in
            configureAgentInfoRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            chatSessionStore.setAppActive(phase == .active)
            if phase == .active {
                // Re-attach any turn whose socket died while we were suspended.
                // Update retained configurations before foreground recovery dials.
                chatSessionStore.updateAgents(agents.map(\.config))
                chatSessionStore.applicationDidBecomeActive()
                configureAgentInfoRefresh()
            } else {
                // Only `.background` — `.inactive` also fires for Control Center / app-switcher peeks,
                // where a healthy live socket must not be torn down and re-handshaked.
                if phase == .background {
                    chatSessionStore.applicationDidEnterBackground()
                }
                infoStore.stopAutoRefresh()
            }
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onDisappear {
            infoStore.stopAutoRefresh()
        }
        .onChange(of: appearance) { _, mode in
            applyAppearance(mode)
        }
    }

    /// Apply the theme at the window level so it covers the main UI and every presented sheet/popover,
    /// and so switching back to System (.unspecified) cleanly reverts to the device setting — which
    /// `.preferredColorScheme(nil)` fails to do live for an already-presented sheet.
    /// Presenting a confirmation dialog while the row's menu is still animating out drops the dialog's
    /// slide-up transition (it pops in on a single frame). Give the menu a beat to finish dismissing,
    /// then present.
    private func afterMenuDismiss(_ present: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            present()
        }
    }

    private func applyAppearance(_ mode: AppearanceMode) {
        let style: UIUserInterfaceStyle =
            switch mode {
            case .system: .unspecified
            case .light: .light
            case .dark: .dark
            }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    @ViewBuilder
    private func destination(for route: ShellRoute) -> some View {
        switch route {
        case .agentHome(let address):
            if let agent = agent(for: address) {
                AgentHomeView(
                    agent: agent,
                    info: infoStore.infoByAddress[address],
                    conversations: conversations(for: address),
                    onNewChat: { path.append(.newChat(address)) },
                    onOpenConversation: { path.append(.conversation($0.id)) },
                    onRenameConversation: { renameConversation($0, to: $1) },
                    onRequestDeleteConversation: { conversation in
                        afterMenuDismiss { deletingConversation = conversation }
                    },
                    onDeleteConversation: deleteConversation
                )
                // The agent card expands into its home (and shrinks back on pop).
                .navigationTransition(.zoom(sourceID: address, in: agentZoomNamespace))
            }

        case .newChat(let address):
            if let agent = agent(for: address) {
                AgentLandingView(
                    agent: agent,
                    info: infoStore.infoByAddress[address],
                    onSend: { input in startConversation(agent: agent, input: input) }
                )
            }

        case .conversation(let id):
            if let conversation = conversations.first(where: { $0.id == id }),
               let agent = agent(for: conversation.agentAddress) {
                let viewModel = chatSessionStore.session(
                    for: conversation,
                    agent: agent.config,
                    onAgentProfile: { profile in
                        guard let merged = infoStore.mergeAuthenticatedProfile(
                            profile,
                            for: agent.address
                        ) else { return }
                        agent.cachedInfo = merged
                    }
                )
                ChatScreen(
                    conversation: conversation,
                    agent: agent,
                    info: infoStore.infoByAddress[agent.address],
                    initialInput: pendingInputs[id],
                    onInitialInputConsumed: { pendingInputs[id] = nil },
                    viewModel: viewModel,
                    sessionStore: chatSessionStore
                )
                .id(id)
            }
        }
    }

    private func conversations(for address: String) -> [ConversationRecord] {
        conversations.filter { $0.agentAddress == address }
    }

    private var agentAddresses: [String] {
        agents.map(\.address)
    }

    private var focusedAgentAddress: String? {
        switch path.last {
        case .agentHome(let address), .newChat(let address):
            return address
        case .conversation(let id):
            return conversations.first { $0.id == id }?.agentAddress
        case nil:
            return nil
        }
    }

    private func refreshAgentInfo() async {
        await infoStore.refreshNow(addresses: agentAddresses)
    }

    private var agentEndpointMap: [String: URL] {
        Dictionary(uniqueKeysWithValues: agents.compactMap { agent in
            agent.preferredEndpoint.map { (agent.address, $0) }
        })
    }

    private func configureAgentInfoRefresh(refreshImmediately: Bool = true) {
        chatSessionStore.updateAgents(agents.map(\.config))
        infoStore.setEndpoints(agentEndpointMap)
        infoStore.startAutoRefresh(
            addresses: agentAddresses,
            focusedAddress: focusedAgentAddress,
            refreshImmediately: refreshImmediately
        )
    }

    private func agent(for address: String) -> AgentConfigRecord? {
        agents.first { $0.address == address }
    }

    private func addAgent(address: String, alias: String, endpoint: URL?) {
        guard let validAddress = AgentAddress(rawValue: address) else { return }

        if let existing = agents.first(where: { $0.address == validAddress.rawValue }) {
            // Re-adding an existing address (e.g. re-scanning a QR that carries no name/endpoint) must
            // not wipe the saved name or LAN endpoint — merge only the values actually supplied.
            if !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing.alias = alias
            }
            if let endpoint {
                existing.preferredEndpoint = endpoint
            }
            existing.updatedAt = .now
        } else {
            modelContext.insert(AgentConfigRecord(address: validAddress.rawValue, alias: alias, preferredEndpoint: endpoint))
        }

        agentEditorDraft = nil
        infoStore.activate(address: validAddress.rawValue)
        infoStore.setEndpoint(endpoint, for: validAddress.rawValue)
        infoStore.refresh(addresses: [validAddress.rawValue])
        path = [.agentHome(validAddress.rawValue)]
    }

    private func renameAgent(_ agent: AgentConfigRecord, alias: String, endpoint: URL?) {
        agent.alias = alias
        agent.preferredEndpoint = endpoint
        agent.updatedAt = .now
        infoStore.setEndpoint(endpoint, for: agent.address)
        infoStore.refresh(addresses: [agent.address])
    }

    private func showAddAgentFromSettings() {
        showingSettings = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            agentEditorDraft = .empty
        }
    }

    private func deleteAgent(_ agent: AgentConfigRecord) {
        let related = conversations.filter { $0.agentAddress == agent.address }
        let relatedIDs = Set(related.map(\.id))
        relatedIDs.forEach(chatSessionStore.removeSession)
        related.forEach(modelContext.delete)
        infoStore.remove(address: agent.address)
        modelContext.delete(agent)

        // If we were viewing (any level of) the deleted agent, pop back to the agent list.
        let referencesDeleted = path.contains { route in
            switch route {
            case .agentHome(let a), .newChat(let a): a == agent.address
            case .conversation(let id): relatedIDs.contains(id)
            }
        }
        if referencesDeleted {
            path.removeAll()
        }
    }

    private func deleteConversation(_ conversation: ConversationRecord) {
        chatSessionStore.removeSession(for: conversation.id)
        modelContext.delete(conversation)
        // Pop the chat if it's open; a delete from the list (not on the stack) is a no-op here.
        path.removeAll { $0 == .conversation(conversation.id) }
    }

    private func renameAgentName(_ agent: AgentConfigRecord, to name: String) {
        agent.alias = name
        agent.updatedAt = .now
        infoStore.refresh(addresses: [agent.address])
    }

    private func renameConversation(_ conversation: ConversationRecord, to title: String) {
        conversation.title = title
        conversation.updatedAt = .now
    }

    private func newChat(for agent: AgentConfigRecord) {
        path = [.agentHome(agent.address), .newChat(agent.address)]
    }

    private func startConversation(agent: AgentConfigRecord, input: AgentInput) {
        let conversation = ConversationRecord(agentAddress: agent.address, mode: .safe)
        modelContext.insert(conversation)
        pendingInputs[conversation.id] = input
        // From the fresh-chat landing, replace it with the real conversation so Back returns to the
        // agent home; otherwise push onto whatever's showing.
        if case .newChat = path.last {
            path[path.count - 1] = .conversation(conversation.id)
        } else {
            path.append(.conversation(conversation.id))
        }
    }

    private func handleNewChatRequest(agentAddress: String?, suggestion: String?) {
        // Only fall back to the first agent when NO agent was named. A deep link that names a specific
        // but unknown agent (deleted, or a stale widget snapshot) must not be silently retargeted to a
        // different agent — that could auto-send the prompt to the wrong one.
        let agent: AgentConfigRecord?
        if let agentAddress {
            guard let resolved = self.agent(for: agentAddress) else { return }
            agent = resolved
        } else {
            agent = agents.first
        }
        guard let agent else {
            agentEditorDraft = .empty
            return
        }

        let trimmedSuggestion = suggestion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedSuggestion.isEmpty {
            newChat(for: agent)
        } else {
            path = [.agentHome(agent.address)]
            startConversation(agent: agent, input: AgentInput(prompt: trimmedSuggestion))
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard let request = ConnectOnionDeepLink.parse(url) else { return }

        if request.opensAgentScanner {
            presentAgentScanner()
            return
        }

        // A navigating deep link must first dismiss any presented sheet/dialog; otherwise the path
        // change happens hidden behind the modal and the tap looks like it did nothing.
        let hadModal = agentEditorDraft != nil || editingAgent != nil || showingSettings
            || deletingAgent != nil || deletingConversation != nil
        agentEditorDraft = nil
        editingAgent = nil
        showingSettings = false
        deletingAgent = nil
        deletingConversation = nil

        func navigate() {
            if let conversationID = request.conversationID {
                openConversation(id: conversationID)
            } else {
                handleNewChatRequest(agentAddress: request.agentAddress, suggestion: request.suggestion)
            }
        }

        if hadModal {
            // Give the sheet a beat to animate out before pushing, matching presentAgentScanner.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                navigate()
            }
        } else {
            navigate()
        }
    }

    private func presentAgentScanner() {
        guard presentedAgentScanner == nil else { return }
        let dismissesPresentedSheet = agentEditorDraft != nil || showingSettings
        agentEditorDraft = nil
        showingSettings = false

        Task { @MainActor in
            if dismissesPresentedSheet {
                try? await Task.sleep(for: .milliseconds(300))
            }
            presentedAgentScanner = .agentQRCode
        }
    }

    private func handleScannedAgent(_ payload: AgentQRCodePayload) {
        presentedAgentScanner = nil

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            agentEditorDraft = AgentEditorDraft(address: payload.address)
        }
    }

    private func openConversation(id: String) {
        guard let uuid = UUID(uuidString: id),
              let conversation = conversations.first(where: { $0.id == uuid }) else { return }
        path = [.agentHome(conversation.agentAddress), .conversation(uuid)]
    }

    private func publishWidgetSnapshot() {
        let shortcuts = agents
            .map { agent -> ConnectOnionAgentShortcut in
                let latestConversation = conversations.first { $0.agentAddress == agent.address }
                let info = infoStore.infoByAddress[agent.address] ?? agent.cachedInfo
                let lastUsedAt = latestConversation?.updatedAt ?? agent.updatedAt
                return ConnectOnionAgentShortcut(
                    address: agent.address,
                    displayName: agent.displayName(info: info),
                    subtitle: widgetSubtitle(for: latestConversation, info: info),
                    lastUsedAt: lastUsedAt,
                    suggestions: ConnectOnionSharedSuggestions.defaults
                )
            }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }

        ConnectOnionWidgetSnapshotStore.save(
            ConnectOnionWidgetSnapshot(updatedAt: .now, agents: Array(shortcuts.prefix(6)))
        )
        WidgetCenter.shared.reloadTimelines(ofKind: "ConnectOnionWidget")
    }

    private func widgetSubtitle(for conversation: ConversationRecord?, info: AgentInfo?) -> String {
        if let conversation {
            return conversation.title
        }

        if info?.online == true {
            return "Online"
        }

        return "Ready"
    }
}

private struct AgentEditorDraft: Identifiable {
    var id = UUID()
    var address = ""
    var alias = ""
    var endpoint: URL?

    static var empty: AgentEditorDraft { AgentEditorDraft() }
}

private enum AgentScannerPresentation: String, Identifiable {
    case agentQRCode

    var id: String { rawValue }
}

#Preview("Loaded Shell") {
    let _ = PreviewFixtures.installMockDependencies()
    AppShellView()
        .modelContainer(PreviewFixtures.seededContainer())
}

#Preview("Empty Shell") {
    let _ = PreviewFixtures.installMockDependencies()
    AppShellView()
        .modelContainer(PreviewFixtures.container())
}
