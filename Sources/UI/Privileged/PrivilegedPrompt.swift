// PrivilegedPrompt — native pre-authorization dialog shown before macOS asks
// for the administrator password.
//
// Replaces the previous AppleScript `display dialog`, whose generic caution-icon
// styling was jarring next to the rest of the app. Only this explanation step is
// ours to design: the password sheet that follows belongs to the OS and is
// deliberately left untouched.
//
// Contract preserved from the old implementation (see Docs / Agents.md):
// cancelling here must return false WITHOUT elevating.

import SwiftUI
import AppKit

/// Structured content for the pre-auth dialog. Replaces the free-form string
/// that used to be interpolated into an AppleScript literal — which also means
/// no more escaping quotes/newlines into `display dialog`.
public struct PrivilegedPromptContent {
    public enum Kind {
        case install, upgrade, uninstall

        var icon: String {
            switch self {
            case .install:   return "shield.lefthalf.filled"
            case .upgrade:   return "arrow.triangle.2.circlepath.circle.fill"
            case .uninstall: return "trash.circle.fill"
            }
        }
        var tint: Color {
            switch self {
            case .install, .upgrade: return DS.Palette.accent
            case .uninstall:         return DS.Palette.error
            }
        }
        var confirmVariant: DSButtonVariant {
            self == .uninstall ? .destructive : .prominent
        }
    }

    public var kind: Kind
    public var title: String
    public var subtitle: String
    /// Optional version transition rendered as `from → to` mono pills.
    public var versionFrom: String? = nil
    public var versionTo: String? = nil
    public var bullets: [String] = []
    public var confirmTitle: String = "继续"

    public init(kind: Kind,
                title: String,
                subtitle: String,
                versionFrom: String? = nil,
                versionTo: String? = nil,
                bullets: [String] = [],
                confirmTitle: String = "继续") {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.versionFrom = versionFrom
        self.versionTo = versionTo
        self.bullets = bullets
        self.confirmTitle = confirmTitle
    }
}

// MARK: - Presenter

@MainActor
enum PrivilegedPrompt {
    /// Keeps the panel alive while it is on screen (an NSPanel with no other
    /// owner would otherwise be deallocated as soon as this scope returns).
    private static var activePanel: NSPanel?

    /// Show the dialog and await the user's decision. Returns true only on an
    /// explicit confirm; closing the window or pressing 取消 returns false, and
    /// the caller must then skip elevation entirely.
    static func confirm(_ content: PrivilegedPromptContent) async -> Bool {
        // Serialize: a second prompt while one is up would orphan the first.
        if activePanel != nil { return false }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resumed = false
            let finish: (Bool) -> Void = { ok in
                guard !resumed else { return }
                resumed = true
                activePanel?.orderOut(nil)
                activePanel = nil
                cont.resume(returning: ok)
            }

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 10),
                // No close button: the choice must be explicit, so there is no
                // ambiguous "dismissed" state that could be read as consent.
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .modalPanel

            let root = PrivilegedPromptView(content: content, onDecision: finish)
            let hosting = NSHostingView(rootView: root)
            panel.contentView = hosting
            panel.setContentSize(hosting.fittingSize)
            panel.center()

            activePanel = panel
            // The app may be menu-bar-only (accessory policy) with no window at
            // all, so front the app explicitly or the dialog can appear behind.
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - View

private struct PrivilegedPromptView: View {
    let content: PrivilegedPromptContent
    let onDecision: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if content.versionFrom != nil || !content.bullets.isEmpty {
                Divider().overlay(DS.Palette.separator)
                details
            }
            Divider().overlay(DS.Palette.separator)
            footer
        }
        .frame(width: 420)
        .background(DS.Palette.cardBg)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            Image(systemName: content.kind.icon)
                .font(DS.Icon.font(DS.Icon.xl, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(content.kind.tint)
                .frame(width: DS.Icon.xl, height: DS.Icon.xl)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(content.title)
                    .font(.dsSection)
                    .foregroundStyle(.primary)
                Text(content.subtitle)
                    .font(.dsBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.xl)
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            if let from = content.versionFrom, let to = content.versionTo {
                HStack(spacing: DS.Spacing.s) {
                    versionPill(from, muted: true)
                    Image(systemName: "arrow.right")
                        .font(DS.Icon.font(DS.Icon.sm, weight: .semibold))
                        .foregroundStyle(.secondary)
                    versionPill(to, muted: false)
                    Spacer(minLength: 0)
                }
            }
            if !content.bullets.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    ForEach(content.bullets, id: \.self) { line in
                        HStack(alignment: .top, spacing: DS.Spacing.s) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(DS.Icon.font(DS.Icon.sm))
                                .foregroundStyle(content.kind.tint.opacity(0.85))
                            Text(line)
                                .font(.dsBody)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.vertical, DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.controlBg.opacity(0.5))
    }

    private func versionPill(_ text: String, muted: Bool) -> some View {
        Text(text)
            .font(.dsMono)
            .foregroundStyle(muted ? .secondary : .primary)
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, DS.Spacing.xs / 2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .fill(muted ? DS.Palette.fill : content.kind.tint.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .stroke(muted ? DS.Palette.border : content.kind.tint.opacity(0.35))
            )
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.s) {
            // Set expectations: the OS password sheet is the next thing they see.
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "lock.fill")
                    .font(DS.Icon.font(DS.Icon.sm))
                Text("下一步需要管理员密码")
                    .font(.dsCaption)
            }
            .foregroundStyle(.secondary)

            Spacer(minLength: DS.Spacing.m)

            Button("取消") { onDecision(false) }
                .dsButton(.secondary)
                .keyboardShortcut(.cancelAction)

            Button(content.confirmTitle) { onDecision(true) }
                .dsButton(content.kind.confirmVariant)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.vertical, DS.Spacing.l)
    }
}
