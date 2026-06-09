import SwiftUI

// MARK: - Quick Open Panel (Pure SwiftUI — no NSViewRepresentable)

struct QuickOpenPanel: View {
    @Environment(FileExplorerStore.self) private var store
    @Environment(RightDockStore.self) private var rightDockStore
    @State private var selectedIndex: Int = 0
    @FocusState private var isSearchFocused: Bool

    private static let maxResults = 50

    private var matches: [FileQuickOpenMatch] { store.quickOpenMatches }
    private var visibleMatches: ArraySlice<FileQuickOpenMatch> {
        matches.prefix(Self.maxResults)
    }

    /// Clamp selectedIndex to valid range (async results may arrive with fewer items)
    private var safeSelectedIndex: Int {
        guard !visibleMatches.isEmpty else { return 0 }
        return min(selectedIndex, visibleMatches.count - 1)
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                TextField("Go to File", text: $store.quickOpenQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isSearchFocused)
                    .onSubmit { openSelected() }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onExitCommand { store.dismissQuickOpen() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if matches.isEmpty && !store.quickOpenQuery.isEmpty {
                Text("No matching files")
                    .font(AppFonts.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(visibleMatches.enumerated()), id: \.element.id) { index, match in
                                QuickOpenRow(
                                    node: match.node,
                                    relativePath: store.relativePath(for: match.node),
                                    matchedIndices: match.matchedIndices,
                                    isSelected: index == safeSelectedIndex
                                )
                                .id(match.id)
                                .contentShape(Rectangle())
                                .onTapGesture { openMatch(match) }
                            }
                        }
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: safeSelectedIndex) { _, newIndex in
                        let items = Array(visibleMatches)
                        if newIndex < items.count {
                            withAnimation(.none) { proxy.scrollTo(items[newIndex].id, anchor: .center) }
                        }
                    }
                }
            }
        }
        .frame(width: 500)
        .background(AppPalette.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .glassEffectIfAvailable(in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .background {
            Button("") { store.dismissQuickOpen() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        }
        .onAppear {
            store.setupQueryAutoSearch()
            store.quickOpenQuery = ""
            store.updateQuickOpenResults()
            selectedIndex = 0
            isSearchFocused = true
        }
        .onChange(of: store.quickOpenQuery) { _, _ in
            selectedIndex = 0
        }
    }

    private func moveSelection(_ delta: Int) {
        let count = visibleMatches.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func openSelected() {
        let items = Array(visibleMatches)
        guard !items.isEmpty else { return }
        openMatch(items[safeSelectedIndex])
    }

    private func openMatch(_ match: FileQuickOpenMatch) {
        let nodeID = match.node.id
        store.dismissQuickOpen()
        rightDockStore.expand(tab: .files)
        DispatchQueue.main.async {
            store.selectNode(nodeID)
        }
    }
}

// MARK: - Row

private struct QuickOpenRow: View {
    let node: FileExplorerNode
    let relativePath: String
    let matchedIndices: [Int]
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(AppFonts.body)
                .foregroundStyle(iconColor)
                .frame(width: 16)

            highlightedName
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(relativePath)
                .font(AppFonts.secondaryLabel)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? AppColors.activeBackground : Color.clear)
    }

    private var highlightedName: Text {
        let matchSet = Set(matchedIndices)
        let chars = Array(node.name)
        var result = Text("")
        for (i, ch) in chars.enumerated() {
            let piece = Text(String(ch))
                .font(.system(size: 13, weight: matchSet.contains(i) ? .bold : .regular))
                .foregroundColor(matchSet.contains(i) ? Color.accentColor : .primary)
            result = result + piece
        }
        return result
    }

    private var iconName: String {
        if node.isDirectory { return "folder.fill" }
        return FileIcons.iconName(for: node.url)
    }

    private var iconColor: Color {
        if node.isDirectory { return Color(nsColor: .systemBlue) }
        return FileIcons.iconColor(for: node.url)
    }
}
