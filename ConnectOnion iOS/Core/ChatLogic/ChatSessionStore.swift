//
//  ChatSessionStore.swift
//
//  Purpose: Implements ChatSessionStore for the Core/ChatLogic module.
//  Collaborates with: ChatEventReducer.
//  References: Apple Swift documentation (https://developer.apple.com/documentation/swift) and
//               the project architecture described in README.md where applicable.
//
//  This file is part of the ConnectOnion iOS application.
//
import Foundation
import Observation

/// App-lifetime owner for chat sessions whose work must survive navigation away from `ChatScreen`.
/// The store publishes only the lightweight state needed by the shell; each screen observes its
/// retained `ChatViewModel` directly.
@MainActor
@Observable
final class ChatSessionStore {
    private(set) var runningConversationIDs: Set<UUID> = []

    @ObservationIgnored private var sessions: [UUID: ChatViewModel] = [:]
    @ObservationIgnored private var visibleConversation: ConversationRecord?
    @ObservationIgnored private var isAppActive = true

    func session(
        for conversation: ConversationRecord,
        agent: AgentConfig,
        client: ConnectOnionClientProviding? = nil,
        onAgentProfile: @escaping @MainActor (AgentProfile) -> Void = { _ in }
    ) -> ChatViewModel {
        if let existing = sessions[conversation.id] {
            existing.updateAgent(agent)
            existing.setAgentProfileHandler(onAgentProfile)
            return existing
        }

        let conversationID = conversation.id
        let viewModel = ChatViewModel(
            conversation: conversation,
            agent: agent,
            client: client,
            onSessionStateChange: { [weak self] state in
                self?.updateRunningState(state, conversationID: conversationID)
            },
            onReplyReady: { [weak self, weak conversation] in
                guard let conversation else { return }
                self?.markReplyReady(for: conversation)
            },
            onReplyCompleted: { [weak self] conversation in
                self?.replyCompleted(for: conversation)
            },
            onAgentProfile: onAgentProfile
        )
        sessions[conversationID] = viewModel
        updateRunningState(viewModel.sessionState, conversationID: conversationID)
        return viewModel
    }

    /// Also update off-screen retained conversations. This is synchronous on
    /// MainActor: it neither starts a connection nor replaces an in-flight task.
    func updateAgents(_ agents: [AgentConfig]) {
        for agent in agents {
            for session in sessions.values where session.agent.address == agent.address {
                session.updateAgent(agent)
            }
        }
    }

    func isGeneratingReply(for conversationID: UUID) -> Bool {
        sessions[conversationID]?.isGeneratingReply ?? false
    }

    func conversationDidAppear(_ conversation: ConversationRecord) {
        visibleConversation = conversation
        if isAppActive {
            conversation.hasUnread = false
        }
    }

    func conversationDidDisappear(_ conversationID: UUID) {
        guard visibleConversation?.id == conversationID else { return }
        visibleConversation = nil
    }

    func setAppActive(_ isActive: Bool) {
        isAppActive = isActive
        if isActive {
            visibleConversation?.hasUnread = false
        }
    }

    /// iOS may suspend or kill us while a turn is in flight, and the WebSocket dies without an error.
    /// Record which sessions were mid-turn so foregrounding can re-attach them.
    func applicationDidEnterBackground() {
        sessions.values.forEach { $0.noteAppWillEnterBackground() }
    }

    /// Re-attach every session that was interrupted. `ChatScreen.onAppear` does not re-fire when the
    /// app returns to an already-visible chat, so without this the transcript stays frozen on
    /// "thinking" forever.
    func applicationDidBecomeActive() {
        sessions.values.forEach { $0.resumeAfterForeground() }
    }

    func removeSession(for conversationID: UUID) {
        if visibleConversation?.id == conversationID {
            visibleConversation = nil
        }
        runningConversationIDs.remove(conversationID)
        sessions.removeValue(forKey: conversationID)?.stop()
    }

    private func updateRunningState(_ state: SessionActiveState, conversationID: UUID) {
        let isRunning = switch state {
        case .connecting, .active, .reconnecting:
            true
        case .idle, .connected, .waiting, .disconnected:
            false
        }

        if isRunning {
            runningConversationIDs.insert(conversationID)
        } else {
            runningConversationIDs.remove(conversationID)
        }
    }

    private func markReplyReady(for conversation: ConversationRecord) {
        let isVisible = isAppActive && visibleConversation?.id == conversation.id
        conversation.hasUnread = !isVisible
    }

    private func replyCompleted(for conversation: ConversationRecord) {
        let isVisible = isAppActive && visibleConversation?.id == conversation.id
        conversation.hasUnread = !isVisible

        // A reply that finished off-screen should already be fully rendered when the user opens it.
        if !isVisible {
            sessions[conversation.id]?.streamingMessageID = nil
        }
    }
}
