import AppKit
import ExpanderEngine

/// Evidence half of Permission Recovery: binary identity, inject health, and the
/// OSLog dump. Nothing here changes state — the Status tab owns every fix action,
/// so this pane can stay collapsed until someone actually needs to file a bug.
final class PermissionDiagnosticsController: NSViewController {
    /// Pushed in by the host on every refresh, so both tabs render one probe
    /// instead of each running their own.
    struct Evidence {
        var bundleID: String
        var appPath: String
        var cdHash: String?
        var designatedRequirement: String?
        var siblingPaths: [String]
        var injectHealth: String
    }

    private let bundleIDLabel = NSTextField(labelWithString: "")
    private let appPathLabel = NSTextField(labelWithString: "")
    private let cdHashLabel = NSTextField(labelWithString: "")
    private let siblingsLabel = NSTextField(wrappingLabelWithString: "")
    private let injectHealthLabel = NSTextField(wrappingLabelWithString: "")

    private var copyLogsButton: CapsuleButton?
    private var refreshLogsButton: CapsuleButton?
    private var logsPreviewView: NSTextView?
    private var logsStatusLabel: NSTextField?

    /// The report reads OSLogStore, so it is built on demand — opening Recovery
    /// or returning from System Settings must not pay for it.
    private var isBuildingReport = false
    private var pendingEvidence: Evidence?

    // MARK: - Layout

    override func loadView() {
        let pane = NSStackView()
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 14
        pane.translatesAutoresizingMaskIntoConstraints = false

        let identityCard = makeIdentityCard()
        let logsCard = makeLogsCard()
        pane.addArrangedSubview(identityCard)
        pane.addArrangedSubview(logsCard)
        for card in [identityCard, logsCard] {
            card.trailingAnchor.constraint(equalTo: pane.trailingAnchor).isActive = true
        }

        view = pane
    }

    private func makeCard() -> GlassCardView {
        let card = GlassCardView(tint: DevTypeTheme.accent.withAlphaComponent(0.05))
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    private func makeIdentityCard() -> GlassCardView {
        let card = makeCard()

        let badge = IconBadgeView(symbol: "number.square", tint: DevTypeTheme.accent, size: 30, pointSize: 13)
        let header = DevTypeTheme.makeLabel(
            "Binary Identity",
            font: DevTypeTheme.font(13, .bold),
            color: DevTypeTheme.textPrimary
        )
        header.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString: """
        TCC grants are keyed to this exact binary. If the path or CDHash below is not the copy \
        you toggled in System Settings, the grant lands on the other copy.
        """)
        hint.font = DevTypeTheme.font(11)
        hint.textColor = DevTypeTheme.textSecondary
        hint.preferredMaxLayoutWidth = 520

        for label in [bundleIDLabel, appPathLabel, cdHashLabel] {
            label.font = DevTypeTheme.mono(11, label === bundleIDLabel ? .semibold : .regular)
            label.textColor = label === bundleIDLabel ? DevTypeTheme.accentBright : DevTypeTheme.textSecondary
        }
        appPathLabel.maximumNumberOfLines = 3
        appPathLabel.cell?.truncatesLastVisibleLine = true
        cdHashLabel.lineBreakMode = .byTruncatingMiddle
        siblingsLabel.font = DevTypeTheme.mono(11)
        siblingsLabel.textColor = DevTypeTheme.statusOrange
        siblingsLabel.preferredMaxLayoutWidth = 520
        siblingsLabel.isHidden = true
        injectHealthLabel.font = DevTypeTheme.font(11, .medium)
        injectHealthLabel.textColor = DevTypeTheme.textSecondary
        injectHealthLabel.preferredMaxLayoutWidth = 520

        let divider = DevTypeTheme.makeHairline()
        let stack = NSStackView(views: [
            hint, bundleIDLabel, appPathLabel, cdHashLabel, siblingsLabel,
            divider, injectHealthLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.contentView.addSubview(badge)
        card.contentView.addSubview(header)
        card.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 14),
            badge.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            header.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            stack.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -16),
            card.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 14),
            // Leading-aligned stack hugs its content, so the rule needs its own width.
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return card
    }

    private func makeLogsCard() -> GlassCardView {
        let card = makeCard()

        let badge = IconBadgeView(symbol: "doc.text.magnifyingglass", tint: DevTypeTheme.accent, size: 30, pointSize: 13)
        let header = DevTypeTheme.makeLabel(
            "Diagnostic Logs",
            font: DevTypeTheme.font(13, .bold),
            color: DevTypeTheme.textPrimary
        )
        header.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString: """
        Copy Logs puts identity, capabilities, expand-gate, and recent OSLog on the clipboard — \
        paste into chat or an issue.
        """)
        hint.font = DevTypeTheme.font(11)
        hint.textColor = DevTypeTheme.textSecondary
        hint.preferredMaxLayoutWidth = 520
        hint.translatesAutoresizingMaskIntoConstraints = false

        let status = DevTypeTheme.makeLabel(
            "Report builds when you open this tab.",
            font: DevTypeTheme.font(11),
            color: DevTypeTheme.textSecondary
        )
        status.translatesAutoresizingMaskIntoConstraints = false
        logsStatusLabel = status

        let previewBlock = NSView()
        previewBlock.wantsLayer = true
        previewBlock.translatesAutoresizingMaskIntoConstraints = false
        previewBlock.layer?.cornerRadius = 10
        previewBlock.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
        previewBlock.layer?.borderWidth = 1
        previewBlock.layer?.borderColor = DevTypeTheme.hairline.cgColor

        let logScroll = NSScrollView()
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.hasVerticalScroller = true
        logScroll.hasHorizontalScroller = false
        logScroll.borderType = .noBorder
        logScroll.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = DevTypeTheme.textSecondary
        textView.font = DevTypeTheme.mono(10)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = "Loading diagnostic report…"
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 520,
            height: CGFloat.greatestFiniteMagnitude
        )
        logScroll.documentView = textView
        logsPreviewView = textView

        previewBlock.addSubview(logScroll)
        NSLayoutConstraint.activate([
            logScroll.topAnchor.constraint(equalTo: previewBlock.topAnchor, constant: 4),
            logScroll.leadingAnchor.constraint(equalTo: previewBlock.leadingAnchor, constant: 4),
            logScroll.trailingAnchor.constraint(equalTo: previewBlock.trailingAnchor, constant: -4),
            logScroll.bottomAnchor.constraint(equalTo: previewBlock.bottomAnchor, constant: -4),
            previewBlock.heightAnchor.constraint(equalToConstant: 240)
        ])

        let copyButton = CapsuleButton(
            title: "Copy Logs",
            symbol: "doc.on.doc",
            style: .primary,
            target: self,
            action: #selector(copyDiagnosticLogs)
        )
        copyLogsButton = copyButton
        let refreshButton = CapsuleButton(
            title: "Refresh",
            symbol: "arrow.triangle.2.circlepath",
            style: .secondary,
            target: self,
            action: #selector(refreshDiagnosticLogs)
        )
        refreshLogsButton = refreshButton

        let buttonRow = NSStackView(views: [copyButton, refreshButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.distribution = .fillEqually
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let content = card.contentView
        content.addSubview(badge)
        content.addSubview(header)
        content.addSubview(hint)
        content.addSubview(status)
        content.addSubview(previewBlock)
        content.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            badge.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            header.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            hint.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            status.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: hint.trailingAnchor),

            previewBlock.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10),
            previewBlock.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            previewBlock.trailingAnchor.constraint(equalTo: hint.trailingAnchor),

            buttonRow.topAnchor.constraint(equalTo: previewBlock.bottomAnchor, constant: 12),
            buttonRow.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 14)
        ])
        return card
    }

    // MARK: - Host hand-off

    /// Latest probe from the host. Cheap — never triggers a report build.
    func apply(_ evidence: Evidence) {
        pendingEvidence = evidence
        guard isViewLoaded else { return }
        bundleIDLabel.stringValue = "Bundle ID: \(evidence.bundleID)"
        appPathLabel.stringValue = "App path: \(evidence.appPath)"
        if let cdHash = evidence.cdHash {
            let requirement = evidence.designatedRequirement
            if let requirement, !requirement.isEmpty {
                cdHashLabel.stringValue = "CDHash: \(cdHash)\nRequirement: \(requirement)"
            } else {
                cdHashLabel.stringValue = "CDHash: \(cdHash)"
            }
        } else {
            cdHashLabel.stringValue = "CDHash: (loading…)"
        }
        if evidence.siblingPaths.isEmpty {
            siblingsLabel.stringValue = ""
            siblingsLabel.isHidden = true
        } else {
            siblingsLabel.stringValue = "Other copies running:\n"
                + evidence.siblingPaths.joined(separator: "\n")
            siblingsLabel.isHidden = false
        }
        injectHealthLabel.stringValue = evidence.injectHealth
    }

    /// Called when the tab becomes visible. Rebuilds so the dump reflects whatever
    /// just happened in Settings; a build already in flight is left alone.
    func didBecomeVisible() {
        if let pendingEvidence { apply(pendingEvidence) }
        reloadReport(copyToPasteboard: false)
    }

    // MARK: - Report

    @objc private func copyDiagnosticLogs() {
        reloadReport(copyToPasteboard: true)
    }

    @objc private func refreshDiagnosticLogs() {
        reloadReport(copyToPasteboard: false)
    }

    private func reloadReport(copyToPasteboard: Bool) {
        guard !isBuildingReport else {
            if copyToPasteboard {
                logsStatusLabel?.stringValue = "Still building report — try Copy Logs again in a moment."
            }
            return
        }
        isBuildingReport = true
        copyLogsButton?.isEnabled = false
        refreshLogsButton?.isEnabled = false
        logsStatusLabel?.stringValue = copyToPasteboard
            ? "Building diagnostic report…"
            : "Refreshing diagnostic logs…"
        logsStatusLabel?.textColor = DevTypeTheme.textSecondary

        DiagnosticReport.buildAsync(cdHash: pendingEvidence?.cdHash) { [weak self] report in
            guard let self else { return }
            self.isBuildingReport = false
            self.copyLogsButton?.isEnabled = true
            self.refreshLogsButton?.isEnabled = true
            self.logsPreviewView?.string = report
            guard copyToPasteboard else {
                self.logsStatusLabel?.stringValue =
                    "Diagnostic ready (\(report.count) chars). Click Copy Logs or select text below."
                self.logsStatusLabel?.textColor = DevTypeTheme.textSecondary
                return
            }
            if DiagnosticReport.copyToPasteboard(report) {
                self.logsStatusLabel?.stringValue =
                    "Copied \(report.count) characters to clipboard. Paste anywhere (⌘V)."
                self.logsStatusLabel?.textColor = DevTypeTheme.statusGreen
                self.copyLogsButton?.title = "Copied!"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.copyLogsButton?.title = "Copy Logs"
                }
                DevTypeLog.permission.info(
                    "[Permission] UI Recovery copied diagnostic report chars=\(report.count, privacy: .public)"
                )
            } else {
                self.logsStatusLabel?.stringValue =
                    "Could not write pasteboard — select text in the log preview and copy manually."
                self.logsStatusLabel?.textColor = DevTypeTheme.accentBright
            }
        }
    }
}
