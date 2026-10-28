//
//  TestSupport.swift
//
//  Purpose: Implements TestSupport for the ConnectOnion iOSTests module.
//  Collaborates with: AgentQRCodePayloadTests, AgentRoutingTests, ChatSessionStoreTests, CustomInstructionsTests, PersonalisationPreferencesTests, Sprint1Tests.
//  References: Apple Swift documentation (https://developer.apple.com/documentation/swift) and
//               the project architecture described in README.md where applicable.
//
//  This file is part of the ConnectOnion iOS application.
//
import Foundation
@testable import ConnectOnion_iOS

/// Shared fixtures + mock `ConnectOnionClientProviding` doubles used across the
/// sprint-labeled unit suites (`Sprint1Tests`, `Sprint2Tests`).
///
/// Every mock is hermetic: no real networking, no LLM, no live agent. The real
/// end-to-end path (app ↔ live `connectonion` agent) is covered separately by the
/// XCUITest `ConnectOnion iOSUITests/ConnectOnion_iOSE2ETests`.
let testAgentAddress = "0xf5ff043a9c5df95eac9387908dea87beb7b59c2a3b04787e3222fdf8209cdee1"

/// Polls `condition` on the MainActor until it holds or the budget elapses. Used by the
/// async `ChatViewModel` suites instead of a single fixed `Task.sleep`, so they settle
/// deterministically regardless of machine load (the streamed events are processed on a
/// detached Task, and the attachment-recovery path deliberately waits ~350 ms before
/// reconnecting).
@MainActor
func waitUntil(maxWaitMilliseconds: Int = 10_000, _ condition: @MainActor () -> Bool) async {
    let step = 25
    var waited = 0
    while waited < maxWaitMilliseconds {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(step))
        waited += step
    }
}

// MARK: - Sprint 1 · connection lifecycle doubles

/// Fails the connection immediately — used to prove a failed connect neither enters
/// the working state nor persists an optimistic user message.
@MainActor
final class FailingConnectOnionClient: ConnectOnionClientProviding {
    func send(input: AgentInput, to agent: AgentConfig, session: ConversationSession) -> AsyncThrowingStream<ConnectOnionClientEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: URLError(.cannotConnectToHost))
        }
    }

    func reconnect(to agent: AgentConfig, session: ConversationSession) -> AsyncThrowingStream<ConnectOnionClientEvent, Error> {
        send(input: AgentInput(prompt: "Reconnect"), to: agent, session: session)
    }

    func sendAskUserResponse(_ answer: String) async throws {}
    func sendApprovalResponse(approved: Bool, scope: String, mode: String?, feedback: String?) async throws {}
    func sendOnboardSubmit(inviteCode: String?, payment: Double?) async throws {}
    func sendPlanReviewResponse(_ message: String) async throws {}
    func disconnect() {}
}

/// Happy path: connect → stream a single agent reply → finish. The hermetic twin of
/// the live E2E smoke test (connection → prompt → streamed response).
@MainActor
final class StreamingConnectOnionClient: ConnectOnionClientProviding {
    private(set) var sentInputs: [AgentInput] = []
    private(set) var sentSessions: [ConversationSession] = []
    var replyText: String

    init(replyText: String = "Connected. Streaming mock response") {
        self.replyText = replyText
    }

    func send(input: AgentInput, to agent: AgentConfig, session: ConversationSession) -> AsyncThrowingStream<ConnectOnionClientEvent, Error> {
        sentInputs.append(input)
        sentSessions.append(session)
        return AsyncThrowingStream { continuation in
            continuation.yield(.connected(
                sessionID: session.remoteSessionID ?? session.id.uuidString,
                status: "connected",
                serverNewer: false,
                session: nil,
                chatItems: []
            ))
            continuation.yield(.output(result: replyText, durationMS: nil, serverNewer: false, session: nil, chatItems: []))
            continuation.finish()
        }
    }

    func reconnect(to agent: AgentConfig, session: ConversationSession) -> AsyncThrowingStream<ConnectOnionClientEvent, Error> {
        send(input: AgentInput(prompt: "Reconnect"), to: agent, session: session)
    }

    func sendAskUserResponse(_ answer: String) async throws {}
    func sendApprovalResponse(approved: Bool, scope: String, mode: String?, feedback: String?) async throws {}
    func sendOnboardSubmit(inviteCode: String?, payment: Double?) async throws {}
    func sendPlanReviewResponse(_ message: String) async throws {}
    func disconnect() {}
}

/// Holds a connected stream open until the test explicitly completes or disconnects it.
@MainActor
final class ControlledReplyClient: ConnectOnionClientProviding {
    private var continuation: AsyncThrowingStream<ConnectOnionClientEvent, Error>.Continuation?
    private(set) var disconnectCount = 0
    private(set) var sentInputs: [AgentInput] = []
    private(set) var sentAgents: [AgentConfig] = []
    private(set) var sentSessions: [ConversationSession] = []

    func send(input: AgentInput, to agent: AgentConfig, session: ConversationSession) -> AsyncThrowingStream<ConnectOnionClientEvent, Error> {
        sentInputs.append(input)
        sentAgents.append(agent)
        sentSessions.append(session)
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            continuation.yield(.connected(
                sessionID: session.remoteSessionID ?? session.id.uuidString,
                status: "connected",
                serverNewer: false,
                session: nil,
                chatItems: []
            ))
        }
    }

    func reconnect(to agent: AgentConfig, session: ConversationSession) -> AsyncThrowingStream<ConnectOnionClientEvent, Error> {
        send(input: AgentInput(prompt: "Reconnect"), to: agent, session: session)
    }

    func complete(with reply: String) {
        continuation?.yield(.output(result: reply, durationMS: nil, serverNewer: false, session: nil, chatItems: []))
        continuation?.finish()
        continuation = nil
    }

    func sendAskUserResponse(_ answer: String) async throws {}
    func sendApprovalResponse(approved: Bool, scope: String, mode: String?, feedback: String?) async throws {}
    func sendOnboardSubmit(inviteCode: String?, payment: Double?) async throws {}
    func sendPlanReviewResponse(_ message: String) async throws {}

    func disconnect() {
        disconnectCount += 1
        continuation?.finish()
        continuation = nil
    }
}

/// Emits one current-turn event and then fails. Regeneration must keep its rollback snapshot until
/// this terminal failure rather than discarding it as soon as the first event arrives.
@MainActor
final class PartialRegenerateFailureClient: ConnectOnionClientProviding {
    func send(input: AgentInput, to agent: AgentConfig, session: ConversationSession) -> AsyncThrowingStream<ConnectOnionClientEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.connected(
                sessionID: session.remoteSessionID ?? session.id.uuidString,
                status: "connected",
                serverNewer: false,
                session: nil,
                chatItems: []
            ))
            continuation.yield(.server(ServerEvent(payload: [
                "type": .string("llm_call"),
                "id": .string("replacement-thinking"),
                "model": .string("co/replacement")
            ])))
            continuation.finish(throwing: URLError(.networkConnectionLost))
        }
    }

    func reconnect(to agent: AgentConfig, session: ConversationSession) -> AsyncThrowingStream<ConnectOnionClientEvent, Error> {
        send(input: AgentInput(prompt: "Reconnect"), to: agent, session: session)
    }

    func sendAskUserResponse(_ answer: String) async throws {}
    func sendApprovalResponse(approved: Bool, scope: String, mode: String?, feedback: String?) async throws {}
    func sendOnboardSubmit(inviteCode: String?, payment: Double?) async throws {}
    func sendPlanReviewResponse(_ message: String) async throws {}
    func disconnect() {}
}

/// Terminates normally without a replacement answer. The view model must treat this as an
/// unsuccessful regeneration and restore the exchange it removed optimistically.
@MainActor
final class EmptyRegenerateOutputClient: ConnectOnionClientProviding {
    func send(input: AgentInput, to agent: AgentConfig, session: ConversationSession) -> AsyncThrowingStream<ConnectOnionClientEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.connected(
                sessionID: session.remoteSessionID ?? session.id.uuidString,
                status: "connected",
                serverNewer: false,
                session: nil,
                chatItems: []
            ))
            continuation.yield(.output(result: "", durationMS: nil, serverNewer: false, session: nil, chatItems: []))
            continuation.finish()
        }
    }

    func reconnect(to agent: AgentConfig, session: ConversationSession) -> AsyncThrowingStream<ConnectOnionClientEvent, Error> {
        send(input: AgentInput(prompt: "Reconnect"), to: agent, session: session)
    }

    func sendAskUserResponse(_ answer: String) async throws {}
    func sendApprovalResponse(approved: Bool, scope: String, mode: String?, feedback: String?) async throws {}
    func sendOnboardSubmit(inviteCode: String?, payment: Double?) async throws {}
    func sendPlanReviewResponse(_ message: String) async throws {}
    func disconnect() {}
}

// MARK: - Sprint 2 · onboarding + attachment doubles

/// Gates the very first prompt behind an ONBOARD_REQUIRED, then replays the original
/// input verbatim after the invite is accepted.
@MainActor
final class OnboardFirstMessageClient: ConnectOnionClientProviding {
    private var continuation: AsyncThrowingStream<ConnectOnionClientEvent, Error>.Continuation?
    private var onboardAccepted = false
    private(set) var sentInputs: [AgentInput] = []
    private(set) var sentSessions: [ConversationSession] = []

    func send(input: AgentInput, to agent: AgentConfig, session: ConversationSession) -> AsyncThrowingStream<ConnectOnionClientEvent, Error> {
        sentInputs.append(input)
        sentSessions.append(session)
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            continuation.yield(.connected(
                sessionID: session.remoteSessionID ?? session.id.uuidString,
                status: "connected",
                serverNewer: false,
                session: nil,
                chatItems: []
            ))

            if !onboardAccepted {
                continuation.yield(.server(ServerEvent(payload: [
                    "type": .string("RUNTIME_INPUT_ACK"),
                    "id": .string("input-ack")
                ])))
                continuation.yield(.server(ServerEvent(payload: [
                    "type": .string("ONBOARD_REQUIRED"),
                    "id": .string("onboard-first-message"),
                    "methods": .array([.string("invite_code")])
                ])))
                return
            }

            continuation.yield(.output(result: "Ready: \(input.prompt)", durationMS: nil, serverNewer: false, session: nil, chatItems: []))
            continuation.finish()
        }
    }

    func reconnect(to agent: AgentConfig, session: ConversationSession) -> AsyncThrowingStream<ConnectOnionClientEvent, Error> {
        send(input: AgentInput(prompt: "Reconnect"), to: agent, session: session)
    }

    func sendAskUserResponse(_ answer: String) async throws {}
    func sendApprovalResponse(approved: Bool, scope: String, mode: String?, feedback: String?) async throws {}
    func sendOnboardSubmit(inviteCode: String?, payment: Double?) async throws {
        onboardAccepted = true
        continuation?.yield(.server(ServerEvent(payload: [
            "type": .string("ONBOARD_SUCCESS"),
            "id": .string("onboard-success"),
            "message": .string("Invite accepted")
        ])))
        continuation?.finish()
    }
    func sendPlanReviewResponse(_ message: String) async throws {}
    func disconnect() {}
}

/// Captures whatever `AgentInput` (prompt/images/files) the composer sends.
@MainActor
final class AttachmentCapturingClient: ConnectOnionClientProviding {
    private(set) var sentInputs: [AgentInput] = []

    func send(input: AgentInput, to agent: AgentConfig, session: ConversationSession) -> AsyncThrowingStream<ConnectOnionClientEvent, Error> {
        sentInputs.append(input)
        return AsyncThrowingStream { continuation in
            continuation.yield(.connected(sessionID: session.id.uuidString, status: "connected", serverNewer: false, session: nil, chatItems: []))
            continuation.yield(.output(result: "Received attachments", durationMS: nil, serverNewer: false, session: nil, chatItems: []))
            continuation.finish()
        }
    }

    func reconnect(to agent: AgentConfig, session: ConversationSession) -> AsyncThrowingStream<ConnectOnionClientEvent, Error> {
        send(input: AgentInput(prompt: "Reconnect"), to: agent, session: session)
    }

    func sendAskUserResponse(_ answer: String) async throws {}
    func sendApprovalResponse(approved: Bool, scope: String, mode: String?, feedback: String?) async throws {}
    func sendOnboardSubmit(inviteCode: String?, payment: Double?) async throws {}
    func sendPlanReviewResponse(_ message: String) async throws {}
    func disconnect() {}
}

/// First send fails mid-stream; a follow-up `reconnect` recovers the reply. Proves the
/// attachment send path auto-reconnects and surfaces the recovered agent message.
@MainActor
final class AttachmentRecoveryClient: ConnectOnionClientProviding {
    private(set) var reconnectCount = 0

    func send(input: AgentInput, to agent: AgentConfig, session: ConversationSession) -> AsyncThrowingStream<ConnectOnionClientEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.connected(sessionID: session.id.uuidString, status: "connected", serverNewer: false, session: nil, chatItems: []))
            continuation.finish(throwing: NSError(domain: "ConnectOnionTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "'list' object has no attribute 'startswith'"
            ]))
        }
    }

    func reconnect(to agent: AgentConfig, session: ConversationSession) -> AsyncThrowingStream<ConnectOnionClientEvent, Error> {
        reconnectCount += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(.connected(sessionID: session.id.uuidString, status: "connected", serverNewer: true, session: nil, chatItems: []))
            continuation.yield(.output(result: "Recovered image reply", durationMS: nil, serverNewer: false, session: nil, chatItems: []))
            continuation.finish()
        }
    }

    func sendAskUserResponse(_ answer: String) async throws {}
    func sendApprovalResponse(approved: Bool, scope: String, mode: String?, feedback: String?) async throws {}
    func sendOnboardSubmit(inviteCode: String?, payment: Double?) async throws {}
    func sendPlanReviewResponse(_ message: String) async throws {}
    func disconnect() {}
}
