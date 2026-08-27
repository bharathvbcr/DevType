import AppKit
import QuartzCore
import ExpanderEngine

/// State of the floating Voice HUD.
public enum VoiceHUDState: Equatable, Sendable {
    case listening(modelName: String)
    case streaming(transcript: String, modelName: String)
    case transcribing(modelName: String)
    case success(text: String)
    case error(message: String)
}

/// Floating Apple Liquid Glass Blob HUD panel showing dynamic organic liquid deformation,
/// live audio harmonic ripples, and elastic expansion as text is spoken in real-time.
@MainActor
public final class VoiceHUDPanel: NSPanel {
    public static let shared = VoiceHUDPanel()

    private let blobContainer: LiquidGlassBlobHUDView
    private let fluidWaveView = FluidWaveVisualizerView()
    private let statusPill: PillBadgeView
    private let micImageView: NSImageView
    private let titleLabel: NSTextField
    private let transcriptLabel: NSTextField
    private let cursorDot: NSTextField
    private var dismissWorkItem: DispatchWorkItem?
    private var currentModelName: String = "Voxtral"

    private static let baseWidth: CGFloat = 280
    private static let baseHeight: CGFloat = 72
    private static let maxWidth: CGFloat = 520
    private static let maxHeight: CGFloat = 160

    public init() {
        self.statusPill = PillBadgeView(text: "Listening", tint: DevTypeTheme.accent, showsDot: true)
        self.titleLabel = DevTypeTheme.makeLabel(
            "Smart Dictation",
            font: DevTypeTheme.font(12, .bold),
            color: DevTypeTheme.textPrimary
        )
        self.transcriptLabel = DevTypeTheme.makeLabel(
            "Speak naturally…",
            font: DevTypeTheme.font(13.5, .medium),
            color: DevTypeTheme.textSecondary,
            wrapping: true
        )
        self.cursorDot = DevTypeTheme.makeLabel(
            "●",
            font: DevTypeTheme.font(10, .bold),
            color: DevTypeTheme.accentBright
        )
        self.blobContainer = LiquidGlassBlobHUDView()

        let micIcon = DevTypeTheme.tintedSymbol(
            "waveform.and.mic",
            size: 14,
            weight: .semibold,
            color: DevTypeTheme.accentBright
        )
        self.micImageView = NSImageView(image: micIcon ?? NSImage())
        self.micImageView.translatesAutoresizingMaskIntoConstraints = false
        self.micImageView.setContentHuggingPriority(.required, for: .horizontal)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.baseWidth, height: Self.baseHeight),
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
        contentView = blobContainer

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 6
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        blobContainer.addSubview(rootStack)

        // Header Row: Mic + Title + Status Pill
        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        headerStack.addArrangedSubview(micImageView)
        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(NSView()) // spacer
        headerStack.addArrangedSubview(statusPill)

        // Text & Live Cursor Row
        let textContainer = NSStackView()
        textContainer.orientation = .horizontal
        textContainer.alignment = .firstBaseline
        textContainer.spacing = 4
        textContainer.translatesAutoresizingMaskIntoConstraints = false

        transcriptLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        transcriptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cursorDot.setContentHuggingPriority(.required, for: .horizontal)

        textContainer.addArrangedSubview(transcriptLabel)
        textContainer.addArrangedSubview(cursorDot)

        // Wave visualizer
        fluidWaveView.translatesAutoresizingMaskIntoConstraints = false
        fluidWaveView.heightAnchor.constraint(equalToConstant: 18).isActive = true

        rootStack.addArrangedSubview(headerStack)
        rootStack.addArrangedSubview(textContainer)
        rootStack.addArrangedSubview(fluidWaveView)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: blobContainer.topAnchor, constant: 12),
            rootStack.leadingAnchor.constraint(equalTo: blobContainer.leadingAnchor, constant: 18),
            rootStack.trailingAnchor.constraint(equalTo: blobContainer.trailingAnchor, constant: -18),
            rootStack.bottomAnchor.constraint(equalTo: blobContainer.bottomAnchor, constant: -10),
            headerStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            textContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            fluidWaveView.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])

        startCursorBlink()
    }

    private func startCursorBlink() {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.2
        anim.duration = 0.6
        anim.autoreverses = true
        anim.repeatCount = .infinity
        cursorDot.wantsLayer = true
        cursorDot.layer?.add(anim, forKey: "cursorBlink")
    }

    // MARK: - Public State Controls

    /// Updates the HUD state and positions it on screen.
    public func updateState(_ state: VoiceHUDState) {
        dismissWorkItem?.cancel()

        switch state {
        case .listening(let modelName):
            currentModelName = modelName
            statusPill.update(text: "Listening", tint: DevTypeTheme.accent)
            titleLabel.stringValue = "Smart Dictation (\(modelName))"
            transcriptLabel.stringValue = "Speak naturally…"
            transcriptLabel.textColor = DevTypeTheme.textSecondary
            cursorDot.isHidden = false
            fluidWaveView.isTranscribing = false
            blobContainer.setGlowActive(true)
            adjustSizeForContent(text: "")
            showOnScreen()

        case .streaming(let transcript, let modelName):
            currentModelName = modelName
            statusPill.update(text: "Live", tint: DevTypeTheme.accentBright)
            titleLabel.stringValue = "Smart Dictation (\(modelName))"
            transcriptLabel.stringValue = transcript.isEmpty ? "Listening…" : transcript
            transcriptLabel.textColor = DevTypeTheme.textPrimary
            cursorDot.isHidden = false
            fluidWaveView.isTranscribing = false
            blobContainer.setGlowActive(true)
            adjustSizeForContent(text: transcript)
            showOnScreen()

        case .transcribing(let modelName):
            statusPill.update(text: "Polishing", tint: DevTypeTheme.accentBright)
            titleLabel.stringValue = "Smart Dictation (\(modelName))"
            cursorDot.isHidden = true
            fluidWaveView.isTranscribing = true
            blobContainer.setGlowActive(true)
            showOnScreen()

        case .success(let text):
            statusPill.update(text: "Inserted", tint: DevTypeTheme.statusGreen)
            cursorDot.isHidden = true
            let preview = text.count > 60 ? String(text.prefix(57)) + "…" : text
            transcriptLabel.stringValue = "\"\(preview)\""
            transcriptLabel.textColor = DevTypeTheme.statusGreen
            fluidWaveView.isTranscribing = false
            blobContainer.setGlowActive(false)
            adjustSizeForContent(text: preview)
            scheduleAutoDismiss(after: 1.2)

        case .error(let message):
            statusPill.update(text: "Failed", tint: DevTypeTheme.statusOrange)
            cursorDot.isHidden = true
            transcriptLabel.stringValue = message
            transcriptLabel.textColor = DevTypeTheme.statusOrange
            fluidWaveView.isTranscribing = false
            blobContainer.setGlowActive(false)
            adjustSizeForContent(text: message)
            scheduleAutoDismiss(after: 3.0)
        }
    }

    /// Updates the streaming transcript in real time, expanding the liquid blob elastically.
    public func updateStreamingTranscript(_ text: String) {
        updateState(.streaming(transcript: text, modelName: currentModelName))
    }

    /// Updates the live audio power level for fluid waveform and liquid blob ripple visualization.
    public func updateAudioLevel(_ level: Float) {
        fluidWaveView.updateLevel(level)
        blobContainer.updateAudioLevel(level)
    }

    // MARK: - Dynamic Liquid Blob Expansion

    private func adjustSizeForContent(text: String) {
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame

        var targetWidth: CGFloat = Self.baseWidth
        var targetHeight: CGFloat = Self.baseHeight

        if !text.isEmpty && text != "Speak naturally…" && text != "Listening…" {
            let font = DevTypeTheme.font(13.5, .medium)
            let maxTextWidth = Self.maxWidth - 44
            let bounding = (text as NSString).boundingRect(
                with: NSSize(width: maxTextWidth, height: 120),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )

            targetWidth = min(Self.maxWidth, max(Self.baseWidth, bounding.width + 48))
            targetHeight = min(Self.maxHeight, max(Self.baseHeight, bounding.height + 48))
        }

        let currentFrame = frame
        let centerX = currentFrame.midX > 0 ? currentFrame.midX : screenRect.midX
        let bottomY = currentFrame.minY > 0 ? currentFrame.minY : (screenRect.minY + 90)

        let newX = max(screenRect.minX + 20, min(screenRect.maxX - targetWidth - 20, centerX - (targetWidth / 2)))
        let newFrame = NSRect(x: newX, y: bottomY, width: targetWidth, height: targetHeight)

        if abs(currentFrame.width - targetWidth) > 2 || abs(currentFrame.height - targetHeight) > 2 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrame(newFrame, display: true)
            }
        }
    }

    private func showOnScreen() {
        if !isVisible {
            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let panelWidth = Self.baseWidth
                let panelHeight = Self.baseHeight
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

// MARK: - Transparent Liquid Glass Blob HUD View

/// Organic multi-layered frosted liquid glass view with Bezier spline blob geometry,
/// audio-energy surface tension ripples, specular Fresnel refraction highlights, and internal caustic glow.
final class LiquidGlassBlobHUDView: NSView {
    private let effectView = NSVisualEffectView()
    private let blobMaskLayer = CAShapeLayer()
    private let glowLayer = CAGradientLayer()
    private let fresnelBorderLayer = CAShapeLayer()
    private var phase: Double = 0.0
    private var currentAudioLevel: Float = 0.0
    private var smoothedAudioLevel: Float = 0.06
    private var blobTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupLiquidLayers()
        startBlobAnimationTimer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        blobTimer?.invalidate()
    }

    private func setupLiquidLayers() {
        // 1. Frosted Vibrancy Effect Layer
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
            DevTypeTheme.accent.withAlphaComponent(0.26).cgColor,
            DevTypeTheme.accentBright.withAlphaComponent(0.10).cgColor,
            NSColor.clear.cgColor
        ]
        glowLayer.locations = [0.0, 0.5, 1.0]
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        layer?.addSublayer(glowLayer)

        // 3. Specular Fresnel Glass Highlight Rim
        fresnelBorderLayer.fillColor = nil
        fresnelBorderLayer.lineWidth = 1.5
        fresnelBorderLayer.strokeColor = DevTypeTheme.accentBright.withAlphaComponent(0.55).cgColor
        layer?.addSublayer(fresnelBorderLayer)

        // Apply organic blob mask to the container
        effectView.wantsLayer = true
        effectView.layer?.mask = blobMaskLayer
    }

    private func startBlobAnimationTimer() {
        blobTimer = Timer.scheduledTimer(withTimeInterval: 0.024, repeats: true) { [weak self] _ in
            self?.tickBlobPhysics()
        }
    }

    public func updateAudioLevel(_ level: Float) {
        currentAudioLevel = max(0.04, min(level, 1.0))
    }

    private func tickBlobPhysics() {
        smoothedAudioLevel = smoothedAudioLevel * 0.82 + currentAudioLevel * 0.18
        phase += 0.04
        updateBlobPath()
    }

    override func layout() {
        super.layout()
        glowLayer.frame = bounds
        updateBlobPath()
    }

    private func updateBlobPath() {
        let width = bounds.width
        let height = bounds.height
        guard width > 20 && height > 20 else { return }

        let path = makeOrganicBlobPath(rect: bounds, phase: phase, audioLevel: CGFloat(smoothedAudioLevel))
        blobMaskLayer.path = path
        fresnelBorderLayer.path = path
    }

    /// Generates an 8-point organic viscous liquid blob closed Bezier spline.
    private func makeOrganicBlobPath(rect: CGRect, phase: Double, audioLevel: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let cx = rect.midX
        let cy = rect.midY
        let rx = rect.width / 2.0
        let ry = rect.height / 2.0

        let pointCount = 8
        var points: [CGPoint] = []

        // Harmonic modulation factors
        let audioPerturbation = audioLevel * 5.0

        for i in 0..<pointCount {
            let angle = (Double(i) / Double(pointCount)) * 2.0 * .pi
            let harmonic1 = sin(angle * 2.0 + phase) * 2.5
            let harmonic2 = cos(angle * 3.0 - phase * 0.7) * (1.5 + Double(audioPerturbation))

            let radiusScale = 1.0 + ((harmonic1 + harmonic2) / 100.0)

            let px = cx + CGFloat(cos(angle) * Double(rx) * radiusScale)
            let py = cy + CGFloat(sin(angle) * Double(ry) * radiusScale)
            points.append(CGPoint(x: px, y: py))
        }

        guard points.count >= 3 else {
            let r = min(rx, ry)
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        }

        // Draw smooth Catmull-Rom / cubic Bezier spline through points
        path.move(to: midpoint(points[points.count - 1], points[0]))

        for i in 0..<points.count {
            let p1 = points[i]
            let p2 = points[(i + 1) % points.count]
            let mid = midpoint(p1, p2)
            path.addQuadCurve(to: mid, control: p1)
        }

        path.closeSubpath()
        return path
    }

    private func midpoint(_ p1: CGPoint, _ p2: CGPoint) -> CGPoint {
        CGPoint(x: (p1.x + p2.x) / 2.0, y: (p1.y + p2.y) / 2.0)
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
