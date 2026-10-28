//
//  ChatSessionStoreTests.swift
//
//  Purpose: Implements ChatSessionStoreTests for the ConnectOnion iOSTests module.
//  Collaborates with: AgentQRCodePayloadTests, AgentRoutingTests, CustomInstructionsTests, PersonalisationPreferencesTests, Sprint1Tests, Sprint2Tests.
//  References: Apple Swift documentation (https://developer.apple.com/documentation/swift) and
//               the project architecture described in README.md where applicable.
//
//  This file is part of the ConnectOnion iOS application.
//
import Foundation
import Testing
@testable import ConnectOnion_iOS

@Suite("Chat sessions — background replies")
struct ChatSessionStoreTests {
    @Test @MainActor func offscreenReplyCompletesAndMarksConversationUnread() async {
        let conversation = ConversationRecord(agentAddress: testAgentAddress)
        let agent = AgentConfigRecord(address: testAgentAddress, alias: "OpenOnion")
        let client = ControlledReplyClient()
        let store = ChatSessionStore()
        let viewModel = store.session(for: conversation, agent: agent.config, client: client)

        // No conversation is visible (store default) → an incoming reply must mark it unread.
        viewModel.send("Finish this in the background")
        await waitUntil { viewModel.sessionState == .active }
        #expect(store.isGeneratingReply(for: conversation.id))

        client.complete(with: "Background reply")
        await waitUntil { viewModel.sessionState == .connected }

        #expect(conversation.hasUnread)
        #expect(viewModel.streamingMessageID == nil)
        #expect(conversation.messages.contains { $0.kind == .agent && $0.content == "Background reply" })
        #expect(store.session(for: conversation, agent: agent.config) === viewModel)
    }

    @Test @MainActor func visibleReplyCompletesWithoutUnreadAndOpeningClearsExistingUnread() async {
        let conversation = ConversationRecord(agentAddress: testAgentAddress, hasUnread: true)
        let agent = AgentConfigRecord(address: testAgentAddress, alias: "OpenOnion")
        let client = ControlledReplyClient()
        let store = ChatSessionStore()
        let viewModel = store.session(for: conversation, agent: agent.config, client: client)

        store.conversationDidAppear(conversation)
        #expect(!conversation.hasUnread)

        viewModel.send("Keep this chat open")
        await waitUntil { viewModel.sessionState == .active }
        #expect(store.isGeneratingReply(for: conversation.id))
        client.complete(with: "Foreground reply")
        await waitUntil { viewModel.sessionState == .connected }

        #expect(!conversation.hasUnread)
        #expect(viewModel.streamingMessageID != nil)
    }

    @Test @MainActor func removingAnActiveSessionStopsItsOwnedClient() async {
        let conversation = ConversationRecord(agentAddress: testAgentAddress)
        let agent = AgentConfigRecord(address: testAgentAddress, alias: "OpenOnion")
        let client = ControlledReplyClient()
        let store = ChatSessionStore()
        let viewModel = store.session(for: conversation, agent: agent.config, client: client)

        viewModel.send("Keep working")
        await waitUntil { viewModel.sessionState == .active }
        #expect(store.isGeneratingReply(for: conversation.id))
        store.removeSession(for: conversation.id)

        #expect(client.disconnectCount == 1)
        #expect(!store.isGeneratingReply(for: conversation.id))
        #expect(viewModel.sessionState == .connected)
    }

    @Test @MainActor func reusingSessionRefreshesEndpointWithoutReplacingConversation() {
        let conversation = ConversationRecord(
            agentAddress: testAgentAddress, remoteSessionID: "existing-remote-session",
            messages: [ChatItem(id: "saved-reply", kind: .agent, content: "Saved response")],
            rawSession: .object(["turn": .number(3)]), lastRenderedEventID: "saved-event"
        )
        let record = AgentConfigRecord(address: testAgentAddress, alias: "Before",
                                       preferredEndpoint: URL(string: "http://192.0.2.1:8001"))
        let client = ControlledReplyClient()
        let store = ChatSessionStore()
        let viewModel = store.session(for: conversation, agent: record.config, client: client)
        let messagesBefore = conversation.messagesData
        let stateBefore = conversation.rawSessionData
        record.preferredEndpoint = URL(string: "http://192.0.2.1:8002")
        record.alias = "After"

        let reused = store.session(for: conversation, agent: record.config)

        #expect(reused === viewModel)
        #expect(reused.conversation === conversation)
        #expect(reused.agent == record.config)
        #expect(conversation.remoteSessionID == "existing-remote-session")
        #expect(conversation.lastRenderedEventID == "saved-event")
        #expect(conversation.messagesData == messagesBefore)
        #expect(conversation.rawSessionData == stateBefore)
        #expect(client.sentAgents.isEmpty)
        #expect(client.disconnectCount == 0)

        // Removing a preferred address must also reach retained chats so that
        // the next resolution is free to use directory/relay discovery.
        record.preferredEndpoint = nil
        store.updateAgents([record.config])
        #expect(viewModel.agent.preferredEndpoint == nil)
    }

    @Test @MainActor func updatesOffscreenSessionsOnlyForTheMatchingAgent() {
        let first = ConversationRecord(agentAddress: testAgentAddress)
        let second = ConversationRecord(agentAddress: testAgentAddress)
        let unrelated = ConversationRecord(agentAddress: "another-agent")
        let record = AgentConfigRecord(address: testAgentAddress,
                                       preferredEndpoint: URL(string: "http://192.0.2.1:8001"))
        let other = AgentConfigRecord(address: "another-agent",
                                      preferredEndpoint: URL(string: "http://192.0.2.2:8001"))
        let store = ChatSessionStore()
        let one = store.session(for: first, agent: record.config, client: ControlledReplyClient())
        let two = store.session(for: second, agent: record.config, client: ControlledReplyClient())
        let three = store.session(for: unrelated, agent: other.config, client: ControlledReplyClient())
        record.preferredEndpoint = URL(string: "http://192.0.2.1:8002")

        store.updateAgents([record.config])

        #expect(one.agent.preferredEndpoint == record.preferredEndpoint)
        #expect(two.agent.preferredEndpoint == record.preferredEndpoint)
        #expect(three.agent == other.config)
        one.updateAgent(other.config)
        #expect(one.agent.address == testAgentAddress)
        #expect(one.agent.preferredEndpoint == record.preferredEndpoint)
    }

    @Test @MainActor func editingEndpointKeepsActiveReplyAndChangesOnlyNextSend() async {
        let conversation = ConversationRecord(agentAddress: testAgentAddress,
                                              remoteSessionID: "preserved-session")
        let originalEndpoint = URL(string: "http://192.0.2.1:8001")
        let updatedEndpoint = URL(string: "http://192.0.2.1:8002")
        let record = AgentConfigRecord(address: testAgentAddress, preferredEndpoint: originalEndpoint)
        let client = ControlledReplyClient()
        let store = ChatSessionStore()
        let viewModel = store.session(for: conversation, agent: record.config, client: client)
        viewModel.send("Already running")
        await waitUntil { viewModel.sessionState == .active }

        record.preferredEndpoint = updatedEndpoint
        store.updateAgents([record.config])

        #expect(viewModel.sessionState == .active)
        #expect(store.isGeneratingReply(for: conversation.id))
        #expect(client.disconnectCount == 0)
        #expect(client.sentAgents.count == 1)
        #expect(client.sentAgents.first?.preferredEndpoint == originalEndpoint)
        client.complete(with: "Reply from the existing connection")
        await waitUntil { viewModel.sessionState == .connected }
        #expect(conversation.messages.contains { $0.content == "Reply from the existing connection" })
        #expect(viewModel.agent.preferredEndpoint == updatedEndpoint)

        viewModel.send("Use the updated route")
        await waitUntil { client.sentAgents.count == 2 }
        #expect(client.sentAgents.last?.preferredEndpoint == updatedEndpoint)
        #expect(client.sentSessions.last?.remoteSessionID == "preserved-session")
        client.complete(with: "New route reply")
        await waitUntil { viewModel.sessionState == .connected }
        #expect(conversation.messages.contains { $0.content == "Reply from the existing connection" })
        #expect(conversation.messages.contains { $0.content == "New route reply" })
    }

    @Test @MainActor func nextReconnectUsesLatestEndpointAndKeepsRemoteSession() async {
        let conversation = ConversationRecord(agentAddress: testAgentAddress,
                                              remoteSessionID: "restore-this-session")
        let record = AgentConfigRecord(address: testAgentAddress,
                                       preferredEndpoint: URL(string: "http://192.0.2.1:8001"))
        let client = ControlledReplyClient()
        let store = ChatSessionStore()
        let viewModel = store.session(for: conversation, agent: record.config, client: client)
        record.preferredEndpoint = URL(string: "http://192.0.2.1:8002")
        store.updateAgents([record.config])

        viewModel.reconnect()
        await waitUntil { client.sentAgents.count == 1 }

        #expect(client.sentAgents.first?.preferredEndpoint == record.preferredEndpoint)
        #expect(client.sentSessions.first?.remoteSessionID == "restore-this-session")
        client.complete(with: "Restored reply")
        await waitUntil { viewModel.sessionState == .connected }
        #expect(conversation.remoteSessionID == "restore-this-session")
    }
}
