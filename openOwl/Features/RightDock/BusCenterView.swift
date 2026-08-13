import SwiftUI

/// Message bus center (REQ-009 Phase 2): who's online, the openOwl inbox
/// stream, and a send box. Backed by `MessageBusService` (flock + JSONL,
/// protocol-identical to the `openowl` CLI).
struct BusCenterView: View {
    @Environment(MessageBusService.self) private var bus

    var body: some View {
        @Bindable var bus = bus
        VStack(spacing: 0) {
            agentsRow
            Divider()
            messageList
            Divider()
            sendBox($bus)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPalette.base)
    }

    // MARK: Agents

    private var agentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(bus.agents.sorted { $0.name < $1.name }) { agent in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(agent.isOnline ? Color.green : AppPalette.border)
                            .frame(width: 6, height: 6)
                        Text(agent.name)
                            .font(AppFonts.caption)
                            .foregroundStyle(agent.isOnline ? AppPalette.textPrimary : AppPalette.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppPalette.surface)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(AppPalette.border, lineWidth: 1))
                    .help(agentHelp(agent))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func agentHelp(_ agent: BusAgentInfo) -> String {
        var parts = [agent.kind]
        if let cwd = agent.cwd { parts.append(cwd) }
        if let paneId = agent.paneId { parts.append("pane \(paneId)") }
        parts.append(agent.isOnline ? "online" : "offline")
        return parts.joined(separator: " · ")
    }

    // MARK: Messages

    private var messageList: some View {
        Group {
            if bus.messages.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 1, pinnedViews: []) {
                        ForEach(bus.messages) { msg in
                            MessageRow(message: msg)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(AppPalette.textTertiary)
            Text("No messages yet")
                .font(AppFonts.caption)
                .foregroundStyle(AppPalette.textTertiary)
            Text("Send one with the box below, or from any agent:\nopenowl bus-send openowl \"...\"")
                .font(AppFonts.badge)
                .multilineTextAlignment(.center)
                .foregroundStyle(AppPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Send

    private func sendBox(_ bus: Bindable<MessageBusService>) -> some View {
        VStack(spacing: 6) {
            TextField("to (agent)", text: bus.sendTo)
                .textFieldStyle(.plain)
                .font(AppFonts.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(AppPalette.surface)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppPalette.border, lineWidth: 1))
                .autocorrectionDisabled()

            HStack(spacing: 6) {
                TextField("message…", text: bus.sendBody)
                    .textFieldStyle(.plain)
                    .font(AppFonts.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(AppPalette.surface)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppPalette.border, lineWidth: 1))
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(bus.sendBody.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send to \(bus.sendTo.wrappedValue)")
            }
        }
        .padding(8)
    }

    private func send() {
        let to = bus.sendTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else { return }
        bus.send(bus.sendBody, to: to)
        bus.sendBody = ""
        bus.refresh()
    }
}

private struct MessageRow: View {
    let message: BusMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(message.from)
                    .font(AppFonts.badge.weight(.semibold))
                    .foregroundStyle(AppPalette.accent)
                Text(shortTime(message.ts))
                    .font(AppFonts.badge)
                    .foregroundStyle(AppPalette.textTertiary)
                Spacer()
                if message.kind != "message" {
                    Text(message.kind.uppercased())
                        .font(AppFonts.badge)
                        .foregroundStyle(AppPalette.textTertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(AppPalette.surface)
                        .clipShape(Capsule())
                }
            }
            Text(message.body)
                .font(AppFonts.caption)
                .foregroundStyle(AppPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func shortTime(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
