import AppKit
import QuartzCore
import ExpanderEngine

/// State of the floating Voice HUD.
public enum VoiceHUDState: Equatable, Sendable {
    case listening(modelName: String)
    case transcribing(modelName: String)
    case success(text: String)
    case error(message: String)
}

/// Floating Apple Liquid Glass HUD panel showing dynamic fluid harmonic wave visualization and transcription state.
@MainActor
public final class VoiceHUDPanel: NSPanel {
    public static let shared = VoiceHUDPanel()

    private let containerView: AppleLiquidGlassHUDView
    private let fluidWaveView = FluidWaveVisualizerView()
    private let statusPill: PillBadgeView
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private var dismissWorkItem: DispatchWorkItem?

    public init() {
        self.statusPill = PillBadgeView(text: "Listening", tint: DevTypeTheme.accent, showsDot: true)
        self.titleLabel = DevTypeTheme.makeLabel(
            "Smart Dictation",
            font: DevTypeTheme.font(13.5, .bold),
            color: DevTypeTheme.textPrimary
        )
        self.detailLabel = DevTypeTheme.makeLabel(
            "Speak now...",
            font: DevTypeTheme.font(11.5, .medium),
            color: DevTypeTheme.textSecondary
        )
        self.containerView = AppleLiquidGlassHUDView(cornerRadius: 22)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 104),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        DevTypeTheme.styleFloatingPanel(self)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true

        setupLayout()
    }

    private func setupLayout() {
        contentView = containerView

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(rootStack)

        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let micIcon = DevTypeTheme.tintedSymbol(
            "waveform.and.mic",
            size: 15,
            weight: .semibold,
            color: DevTypeTheme.accentBright
        )
        let micImageView = NSImageView(image: micIcon ?? NSImage())
        micImageView.translatesAutoresizingMaskIntoConstraints = false
        micImageView.setContentHuggingPriority(.required, for: .horizontal)

        headerStack.addArrangedSubview(micImageView)
        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(NSView()) // spacer
        headerStack.addArrangedSubview(statusPill)

        fluidWaveView.translatesAutoresizingMaskIntoConstraints = false
        fluidWaveView.heightAnchor.constraint(equalToConstant: 28).isActive = true

        rootStack.addArrangedSubview(headerStack)
        rootStack.addArrangedSubview(fluidWaveView)
        rootStack.addArrangedSubview(detailLabel)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 14),
            rootStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            rootStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            rootStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -12),
            headerStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            fluidWaveView.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])
    }

    // MARK: - Public State Controls

    /// Updates the HUD state and positions it on screen.
    public func updateState(_ state: VoiceHUDState) {
        dismissWorkItem?.cancel()

        switch state {
        case .listening(let modelName):
            statusPill.update(text: "Listening", tint: DevTypeTheme.accent)
            titleLabel.stringValue = "Smart Dictation"
            detailLabel.stringValue = "Using \(modelName) • Speak naturally"
            detailLabel.textColor = DevTypeTheme.textSecondary
            fluidWaveView.isTranscribing = false
            containerView.setGlowActive(true)
            showOnScreen()

        case .transcribing(let modelName):
            statusPill.update(text: "Transcribing", tint: DevTypeTheme.accentBright)
            detailLabel.stringValue = "Processing with \(modelName)..."
            detailLabel.textColor = DevTypeTheme.accentBright
            fluidWaveView.isTranscribing = true
            containerView.setGlowActive(true)
            showOnScreen()

        case .success(let text):
            statusPill.update(text: "Inserted", tint: DevTypeTheme.statusGreen)
            let preview = text.count > 45 ? String(text.prefix(42)) + "..." : text
            detailLabel.stringValue = "\"\(preview)\""
            detailLabel.textColor = DevTypeTheme.statusGreen
            fluidWaveView.isTranscribing = false
            containerView.setGlowActive(false)
            scheduleAutoDismiss(after: 1.2)

        case .error(let message):
            statusPill.update(text: "Failed", tint: DevTypeTheme.statusOrange)
            detailLabel.stringValue = message
            detailLabel.textColor = DevTypeTheme.statusOrange
            fluidWaveView.isTranscribing = false
            containerView.setGlowActive(false)
            scheduleAutoDismiss(after: 3.0)
        }
    }

    /// Updates the live audio power level for fluid waveform visualization.
    public func updateAudioLevel(_ level: Float) {
        fluidWaveView.updateLevel(level)
    }

    private func showOnScreen() {
        if !isVisible {
            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let panelWidth: CGFloat = 340
                let panelHeight: CGFloat = 110
                let x = screenRect.midX - (panelWidth / 2)
                let y = screenRect.minY + 90
                setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
            }
            alphaValue = 0.0
            makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1.0
            }
        }
    }

    private func scheduleAutoDismiss(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0.0
            }, completionHandler: {
                self.orderOut(nil)
            })
        }
        self.dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func hide() {
        dismissWorkItem?.cancel()
        orderOut(nil)
    }
}

// MARK: - Apple Liquid Glass HUD Container View

/// Multi-layered frosted liquid glass view with specular fresnel highlight and ambient caustic glow.
final class AppleLiquidGlassHUDView: NSView {
    private let cornerRadius: CGFloat
    private let effectView = NSVisualEffectView()
    private let glowLayer = CAGradientLayer()
    private let glassBorderLayer = CAGradientLayer()

    init(cornerRadius: CGFloat = 22) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        setupGlassLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupGlassLayers() {
        // 1. Frosted Vibrancy Effect
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // 2. Liquid Ambient Glow Behind Glass
        glowLayer.type = .radial
        glowLayer.colors = [
            DevTypeTheme.accent.withAlphaComponent(0.22).cgColor,
            DevTypeTheme.accentBright.withAlphaComponent(0.08).cgColor,
            NSColor.clear.cgColor
        ]
        glowLayer.locations = [0.0, 0.5, 1.0]
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        layer?.addSublayer(glowLayer)

        // 3. Specular Fresnel Glass Border
        glassBorderLayer.colors = [
            NSColor.white.withAlphaComponent(0.40).cgColor,
            DevTypeTheme.accent.withAlphaComponent(0.25).cgColor,
            NSColor.white.withAlphaComponent(0.10).cgColor
        ]
        glassBorderLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
        glassBorderLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        layer?.addSublayer(glassBorderLayer)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = cornerRadius
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = true

        glowLayer.frame = bounds
        glowLayer.cornerRadius = cornerRadius

        // Outer glass hairline
        layer?.borderWidth = 1.0
        layer?.borderColor = DevTypeTheme.accent.withAlphaComponent(0.35).cgColor

        glassBorderLayer.frame = bounds
        glassBorderLayer.cornerRadius = cornerRadius
    }

    func setGlowActive(_ active: Bool) {
        let opacity: Float = active ? 1.0 : 0.0
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = glowLayer.opacity
        anim.toValue = opacity
        anim.duration = 0.3
        glowLayer.add(anim, forKey: "glowOpacity")
        glowLayer.opacity = opacity
    }
}

// MARK: - Fluid Harmonic Wave Visualizer View

/// Smooth multi-harmonic sine wave visualizer inspired by Apple Intelligence and Siri fluid waveforms.
final class FluidWaveVisualizerView: NSView {
    private var currentAudioLevel: Float = 0.0
    private var smoothedLevel: Float = 0.08
    private var phase: Double = 0.0
    private var displayTimer: Timer?

    var isTranscribing = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        startAnimationTimer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        displayTimer?.invalidate()
    }

    private func startAnimationTimer() {
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.tickAnimation()
        }
    }

    public func updateLevel(_ level: Float) {
        currentAudioLevel = max(0.06, min(level, 1.0))
    }

    private func tickAnimation() {
        // Smooth audio energy envelope with low-pass filter
        smoothedLevel = smoothedLevel * 0.80 + currentAudioLevel * 0.20
        phase += isTranscribing ? 0.12 : 0.06
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let width = bounds.width
        let height = bounds.height
        let midY = height / 2.0

        guard width > 0 && height > 0 else { return }

        context.saveGState()

        // Draw 3 harmonic fluid sine wave layers with phase and color offsets
        let waveConfigs: [(frequency: Double, amplitudeMultiplier: CGFloat, phaseOffset: Double, color: NSColor, lineWidth: CGFloat)] = [
            (frequency: 1.5, amplitudeMultiplier: 0.50, phaseOffset: 0.0, color: DevTypeTheme.accent.withAlphaComponent(0.35), lineWidth: 1.5),
            (frequency: 2.2, amplitudeMultiplier: 0.75, phaseOffset: 2.094, color: DevTypeTheme.accentBright.withAlphaComponent(0.60), lineWidth: 2.0),
            (frequency: 3.0, amplitudeMultiplier: 1.00, phaseOffset: 4.188, color: NSColor.white.withAlphaComponent(0.95), lineWidth: 2.2)
        ]

        let amplitudeBase = CGFloat(smoothedLevel) * (height * 0.42)

        for config in waveConfigs {
            let path = CGMutablePath()
            let amp = amplitudeBase * config.amplitudeMultiplier

            var isFirst = true
            let step: CGFloat = 3.0

            for x in stride(from: 0.0, through: width, by: step) {
                // Windowing envelope: damp wave at the left and right edges (Tukey / Gaussian window)
                let normalizedX = x / width
                let envelope = sin(normalizedX * .pi)

                let angle = (Double(normalizedX) * config.frequency * 2.0 * .pi) + phase + config.phaseOffset
                let y = midY + (sin(angle) * Double(amp) * Double(envelope))

                if isFirst {
                    path.move(to: CGPoint(x: x, y: y))
                    isFirst = false
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            context.setLineWidth(config.lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(config.color.cgColor)
            context.addPath(path)
            context.strokePath()
        }

        context.restoreGState()
    }
}
