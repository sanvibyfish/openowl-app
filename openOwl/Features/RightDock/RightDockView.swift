import AppKit
import SwiftUI

/// Right-hand inspector panel. Hosts Files / Git as switchable tabs
/// and keeps both views mounted to preserve their `@State` (editor tabs,
/// commit drafts, scroll positions, etc.).
///
/// The expanded panel owns its tab switcher, project context, collapse, and
/// fullscreen affordances. `RightDockRail` is only the collapsed entry point.
struct RightDockView: View {
    @Environment(RightDockStore.self) private var dock
    @Environment(ProjectStore.self) private var projectStore

    /// Provided by the host so we can clamp `setWidth(...)` to a sensible upper
    /// bound (currently 50% of the window) without RightDockStore needing to
    /// know about geometry.
    let hostWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            // Drag handle on the left edge — hidden when fullscreen (ignores
            // `width`) or when the active tab is list-only (effectiveWidth
            // overrides `width` with a fixed `listOnlyWidth` either way).
            if !dock.isFullscreen && dock.showsDetailForActiveTab {
                ResizeHandle(
                    // Drag from the edge the user can actually see. `width` is a
                    // stored preference that effectiveWidth may floor up (an
                    // upgrade carrying the old 420 default renders at 520), and
                    // anchoring the gesture to the stale value made the first
                    // narrow-drag after upgrade do nothing at all.
                    currentWidth: dock.effectiveWidth(hostWidth: hostWidth),
                    onResizeStart: {
                        dock.beginInteractiveResize()
                    },
                    onResize: { proposed in
                        dock.setWidth(
                            proposed,
                            maxWidth: RightDockStore.maxNormalWidth(hostWidth: hostWidth)
                        )
                    },
                    onResizeEnd: {
                        dock.endInteractiveResize()
                    }
                )
            }

            VStack(spacing: 0) {
                dockHeader

                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppPalette.base)
    }

    private var dockHeader: some View {
        HStack(spacing: 0) {
            // Flat underline tabs — same quiet inspector language as the
            // left session list headers (no floating pill chrome).
            ForEach(RightDockTab.allCases) { tab in
                let selected = dock.activeTab == tab
                Button {
                    dock.activeTab = tab
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 11, weight: .medium))
                        Text(tab.title)
                            .font(AppFonts.caption.weight(selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? AppPalette.textPrimary : AppPalette.textTertiary)
                    .padding(.horizontal, 12)
                    .frame(height: AppSpacing.headerHeight)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(selected ? AppPalette.accent : Color.clear)
                            .frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }

            // Context only — path is the tooltip; name yields when dock is narrow
            if let project = activeProject {
                Text(project.displayName)
                    .font(AppFonts.caption)
                    .foregroundStyle(AppPalette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 10)
                    .layoutPriority(-1)
                    .help(abbreviatedPath(project.url))
                    .accessibilityLabel("Project \(project.displayName)")
            }

            Spacer(minLength: 4)

            if let project = activeProject {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([project.url])
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.icon(
                    font: .system(size: 11, weight: .medium),
                    size: AppSpacing.headerHeight
                ))
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal project in Finder")
            }

            Button {
                dock.toggleFullscreen()
            } label: {
                Image(systemName: dock.isFullscreen
                    ? "arrow.down.right.and.arrow.up.left.square.fill"
                    : "arrow.up.left.and.arrow.down.right.square")
            }
            .buttonStyle(.icon(
                isActive: dock.isFullscreen,
                font: .system(size: 11, weight: .medium),
                size: AppSpacing.headerHeight
            ))
            .help(dock.isFullscreen ? "Exit fullscreen" : "Fullscreen panel")
            .accessibilityLabel(dock.isFullscreen ? "Exit fullscreen" : "Fullscreen panel")

            Button {
                dock.collapse()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.icon(
                font: .system(size: 11, weight: .semibold),
                size: AppSpacing.headerHeight
            ))
            .help("Collapse panel")
            .accessibilityLabel("Collapse panel")
        }
        .padding(.trailing, 4)
        // Elevated to pair with left ProjectSessionList header surface.
        .panelToolHeader(background: AppPalette.elevated)
    }

    private var activeProject: ProjectItem? {
        guard let activeProjectID = projectStore.activeProjectID else { return nil }
        return projectStore.projects.first { $0.id == activeProjectID }
    }

    private func abbreviatedPath(_ url: URL) -> String {
        (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
    }

    private var contentArea: some View {
        ZStack {
            // Both views stay mounted so their @State (editor tabs, commit
            // drafts, scroll positions) survives tab switches. Visibility is
            // controlled by opacity + allowsHitTesting.
            NavigationStack {
                FileExplorerView()
            }
            .opacity(dock.activeTab == .files ? 1 : 0)
            .allowsHitTesting(dock.activeTab == .files)

            NavigationStack {
                GitChangesView()
            }
            .opacity(dock.activeTab == .git ? 1 : 0)
            .allowsHitTesting(dock.activeTab == .git)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Resize Handle

/// 4pt-wide invisible hit zone on the left edge. Reports an absolute proposed
/// width (computed from the width-at-drag-start + cumulative translation) so
/// the gesture is immune to view rebuilds — a delta-based @GestureState
/// version produced visible jitter as the dock rebuilt on every width change.
private struct ResizeHandle: View {
    let currentWidth: CGFloat
    let onResizeStart: () -> Void
    let onResize: (CGFloat) -> Void
    let onResizeEnd: () -> Void

    @State private var dragStartWidth: CGFloat?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 4)
            .overlay(
                Rectangle()
                    .fill(hovering ? AppPalette.accent.opacity(0.4) : Color.clear)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                // .global is critical: as the dock grows the handle moves
                // left with it, and a .local coordinate space would make the
                // mouse appear to teleport relative to the handle each frame,
                // producing a feedback-loop jitter. Global coords are stable
                // because they don't depend on view position.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = currentWidth
                            onResizeStart()
                        }
                        // Handle is on the LEFT edge: dragging left makes the
                        // panel wider, so subtract the (negative) translation.
                        let proposed = (dragStartWidth ?? currentWidth) - value.translation.width
                        onResize(proposed)
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        onResizeEnd()
                    }
            )
    }
}
