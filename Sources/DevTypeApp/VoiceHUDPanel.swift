import AppKit
import DevTypeSafety
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

/// Floating dictation HUD: Liquid Glass on macOS 26+, material fallback below.
/// Non-activating — never steals key focus from the field receiving dictation.
@MainActor
public final class VoiceHUDPanel: NSPanel {
    public static let shared = VoiceHUDPanel()

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    private let blobContainer: LiquidGlassBlobHUDView
    private let fluidWaveView = FluidWaveVisualizerView()
    private let statusPill: PillBadgeView
    private let micImageView: NSImageView
    private let titleLabel: NSTextField
    private let transcriptLabel: NSTextField
    private let cursorDot: NSTextField
    private var dismissWorkItem: DispatchWorkItem?
    private var currentModelName: String = "Voxtral"
    private var pendingTargetSize: CGSize?
    private var isResizeScheduled = false
    private var usesRealGlass = false

    private static let baseWidth: CGFloat = 280
    private static let baseHeight: CGFloat = 72
    private static let maxWidth: CGFloat = 520
    private static let maxHeight: CGFloat = 200

    public init() {
        let loc = LocalizationManager.shared
        self.statusPill = PillBadgeView(text: loc.s("voice.hud.status.listening"), tint: DevTypeTheme.accent, showsDot: true)
        self.titleLabel = DevTypeTheme.makeLabel(
            loc.s("palette.voice.dictation"),
            font: DevTypeTheme.font(12, .bold),
            color: DevTypeTheme.textPrimary
        )
        self.transcriptLabel = DevTypeTheme.makeLabel(
            loc.s("voice.hud.placeholder"),
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
        self.micImageView.setAccessibilityElement(false)

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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        usesRealGlass = blobContainer.isUsingLiquidGlass
        hasShadow = !usesRealGlass

        setAccessibilityTitle(loc.s("voice.hud.ax.title"))
        setAccessibilityLabel(loc.s("voice.hud.ax.title"))

        setupLayout()
    }

    private func setupLayout() {
        contentView = blobContainer

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 6
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        blobContainer.contentHost.addSubview(rootStack)

        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        headerStack.addArrangedSubview(micImageView)
        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(spacer)
        headerStack.addArrangedSubview(statusPill)

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

        fluidWaveView.translatesAutoresizingMaskIntoConstraints = false
        fluidWaveView.heightAnchor.constraint(equalToConstant: 18).isActive = true

        rootStack.addArrangedSubview(headerStack)
        rootStack.addArrangedSubview(textContainer)
        rootStack.addArrangedSubview(fluidWaveView)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: blobContainer.contentHost.topAnchor, constant: 12),
            rootStack.leadingAnchor.constraint(equalTo: blobContainer.contentHost.leadingAnchor, constant: 18),
            rootStack.trailingAnchor.constraint(equalTo: blobContainer.contentHost.trailingAnchor, constant: -18),
            rootStack.bottomAnchor.constraint(equalTo: blobContainer.contentHost.bottomAnchor, constant: -10),
            headerStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            textContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            fluidWaveView.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])

        refreshCursorBlink()
    }

    private func refreshCursorBlink() {
        cursorDot.wantsLayer = true
        cursorDot.layer?.removeAnimation(forKey: "cursorBlink")
        guard !DevTypeAccessibility.reduceMotion else {
            cursorDot.alphaValue = 1
            return
        }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.2
        anim.duration = 0.6
        anim.autoreverses = true
        anim.repeatCount = .infinity
        cursorDot.layer?.add(anim, forKey: "cursorBlink")
    }

    // MARK: - Public State Controls

    /// Updates the HUD state and positions it on screen.
    public func updateState(_ state: VoiceHUDState) {
        dismissWorkItem?.cancel()
        let loc = LocalizationManager.shared

        switch state {
        case .listening(let modelName):
            currentModelName = modelName
            statusPill.update(text: loc.s("voice.hud.status.listening"), tint: DevTypeTheme.accent)
            titleLabel.stringValue = loc.s("voice.hud.title", modelName)
            transcriptLabel.stringValue = loc.s("voice.hud.placeholder")
            transcriptLabel.textColor = DevTypeTheme.textSecondary
            cursorDot.isHidden = false
            fluidWaveView.isTranscribing = false
            blobContainer.setActive(true)
            scheduleSize(forText: "")
            showOnScreen()

        case .streaming(let transcript, let modelName):
            currentModelName = modelName
            statusPill.update(text: loc.s("voice.hud.status.live"), tint: DevTypeTheme.accentBright)
            titleLabel.stringValue = loc.s("voice.hud.title", modelName)
            let prompt = loc.s("voice.hud.listening")
            transcriptLabel.stringValue = transcript.isEmpty ? prompt : transcript
            transcriptLabel.textColor = DevTypeTheme.textPrimary
            cursorDot.isHidden = false
            fluidWaveView.isTranscribing = false
            blobContainer.setActive(true)
            scheduleSize(forText: transcript)
            showOnScreen()

        case .transcribing(let modelName):
            statusPill.update(text: loc.s("voice.hud.status.polishing"), tint: DevTypeTheme.accentBright)
            titleLabel.stringValue = loc.s("voice.hud.title", modelName)
            cursorDot.isHidden = true
            fluidWaveView.isTranscribing = true
            updateAudioLevel(0)
            blobContainer.setActive(true)
            showOnScreen()

        case .success(let text):
            statusPill.update(text: loc.s("voice.hud.status.inserted"), tint: DevTypeTheme.statusGreen)
            cursorDot.isHidden = true
            let preview = text.count > 60 ? String(text.prefix(57)) + "…" : text
            transcriptLabel.stringValue = "\"\(preview)\""
            transcriptLabel.textColor = DevTypeTheme.statusGreen
            fluidWaveView.isTranscribing = false
            updateAudioLevel(0)
            blobContainer.setActive(false)
            scheduleSize(forText: preview)
            showOnScreen()
            scheduleAutoDismiss(after: 1.2)

        case .error(let message):
            statusPill.update(text: loc.s("voice.hud.status.failed"), tint: DevTypeTheme.statusOrange)
            cursorDot.isHidden = true
            transcriptLabel.stringValue = message
            transcriptLabel.textColor = DevTypeTheme.statusOrange
            fluidWaveView.isTranscribing = false
            updateAudioLevel(0)
            blobContainer.setActive(false)
            scheduleSize(forText: message)
            showOnScreen()
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

    private func scheduleSize(forText text: String) {
        let font = DevTypeTheme.font(13.5, .medium)
        let size = LiquidBlobGeometry.hudSize(
            forText: text,
            font: font,
            chromeHeight: LiquidBlobGeometry.defaultChromeHeight,
            base: CGSize(width: Self.baseWidth, height: Self.baseHeight),
            maximum: CGSize(width: Self.maxWidth, height: Self.maxHeight)
        )
        pendingTargetSize = size
        guard !isResizeScheduled else { return }
        isResizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingResize()
        }
    }

    private func flushPendingResize() {
        isResizeScheduled = false
        guard let size = pendingTargetSize else { return }
        pendingTargetSize = nil
        applyFrame(size: size, animated: true)
    }

    private func applyFrame(size: CGSize, animated: Bool) {
        let screen = screenForPlacement()
        let screenRect = screen.visibleFrame

        let currentFrame = frame
        let centerX = currentFrame.width > 0 ? currentFrame.midX : screenRect.midX
        let bottomY: CGFloat = {
            if currentFrame.height > 0, isVisible {
                return currentFrame.minY
            }
            return screenRect.minY + 90
        }()

        let newX = max(
            screenRect.minX + 20,
            min(screenRect.maxX - size.width - 20, centerX - (size.width / 2))
        )
        let newFrame = NSRect(x: newX, y: bottomY, width: size.width, height: size.height)

        let deltaW = abs(currentFrame.width - size.width)
        let deltaH = abs(currentFrame.height - size.height)
        guard deltaW > 2 || deltaH > 2 || !isVisible else { return }

        if !animated || DevTypeAccessibility.reduceMotion {
            setFrame(newFrame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            self.animator().setFrame(newFrame, display: true)
        }
    }

    private func screenForPlacement() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func showOnScreen() {
        blobContainer.setAnimationEnabled(true)
        fluidWaveView.setAnimationEnabled(true)
        refreshCursorBlink()

        if !isVisible {
            let size = pendingTargetSize
                ?? CGSize(width: Self.baseWidth, height: Self.baseHeight)
            applyFrame(size: size, animated: false)
            alphaValue = 0
            orderFrontRegardless()
            if DevTypeAccessibility.reduceMotion {
                alphaValue = 1
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.20
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.animator().alphaValue = 1.0
                }
            }
        } else {
            orderFrontRegardless()
        }
    }

    private func scheduleAutoDismiss(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dismissAnimated()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func dismissAnimated() {
        if DevTypeAccessibility.reduceMotion {
            pauseAnimation()
            orderOut(nil)
            alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pauseAnimation()
                self.orderOut(nil)
                self.alphaValue = 1
            }
        })
    }

    private func pauseAnimation() {
        updateAudioLevel(0)
        blobContainer.setAnimationEnabled(false)
        fluidWaveView.setAnimationEnabled(false)
        cursorDot.layer?.removeAnimation(forKey: "cursorBlink")
    }

    public func hide() {
        dismissWorkItem?.cancel()
        pauseAnimation()
        orderOut(nil)
    }
}

// MARK: - Transparent Liquid Glass Blob HUD View

/// Organic Liquid Glass (macOS 26+) or material fallback, masked to an inset blob path.
final class LiquidGlassBlobHUDView: NSView {
    /// Host for HUD chrome — lives inside the glass `contentView` / solid fill.
    let contentHost = NSView()

    private(set) var isUsingLiquidGlass = false

    private var glassSurface: NSView?
    private var visualEffectView: NSVisualEffectView?
    private var solidBackground: NSView?
    private let rimLayer = CAShapeLayer()
    private var displayLink: CADisplayLink?
    private var phase: Double = 0.0
    private var currentAudioLevel: Float = 0.0
    private var smoothedAudioLevel: Float = 0.06
    private var animationEnabled = false
    private var glowActive = true
    private var lastMaskSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupSurface()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        displayLink?.invalidate()
    }

    private func setupSurface() {
        if DevTypeAccessibility.reduceTransparency {
            let solid = NSView()
            solid.wantsLayer = true
            solid.layer?.backgroundColor = DevTypeTheme.cardBackgroundSolid.cgColor
            solid.translatesAutoresizingMaskIntoConstraints = false
            addSubview(solid)
            contentHost.translatesAutoresizingMaskIntoConstraints = false
            solid.addSubview(contentHost)
            solidBackground = solid
            NSLayoutConstraint.activate(pin(solid, to: self) + pin(contentHost, to: solid))
            installRim(on: self)
            return
        }

        if installLiquidGlass() {
            isUsingLiquidGlass = true
            return
        }

        installVisualEffectFallback()
    }

    private func installLiquidGlass() -> Bool {
        guard #available(macOS 26.0, *),
              let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type else {
            return false
        }
        let glass = glassClass.init(frame: bounds)
        // Attempt clear style (NSGlassEffectView.Style.clear ≈ 1). Rejected keys
        // are ignored; tint + contentView are required for a usable surface.
        _ = DTSetValueForKeyCatching(glass, NSNumber(value: 1), "style")
        _ = DTSetValueForKeyCatching(glass, NSNumber(value: true), "effectIsInteractive")
        let tint = DevTypeTheme.accent.withAlphaComponent(0.12)
        let configured =
            DTSetValueForKeyCatching(glass, tint, "tintColor")
            && DTSetValueForKeyCatching(glass, contentHost, "contentView")
        guard configured else { return false }

        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate(pin(glass, to: self))
        contentHost.translatesAutoresizingMaskIntoConstraints = true
        contentHost.frame = bounds
        contentHost.autoresizingMask = [.width, .height]
        glassSurface = glass
        return true
    }

    private func installVisualEffectFallback() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(contentHost)
        NSLayoutConstraint.activate(pin(effect, to: self) + pin(contentHost, to: effect))
        visualEffectView = effect
        installRim(on: self)
    }

    private func installRim(on view: NSView) {
        rimLayer.fillColor = nil
        rimLayer.lineWidth = 1.2
        rimLayer.strokeColor = DevTypeTheme.accentBright.withAlphaComponent(0.45).cgColor
        view.wantsLayer = true
        view.layer?.addSublayer(rimLayer)
    }

    private func pin(_ child: NSView, to parent: NSView) -> [NSLayoutConstraint] {
        [
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ]
    }

    func setAnimationEnabled(_ enabled: Bool) {
        animationEnabled = enabled
        if enabled {
            startDisplayLinkIfNeeded()
        } else {
            stopDisplayLink()
            smoothedAudioLevel = 0.06
            currentAudioLevel = 0
            updateBlobPath()
        }
    }

    func setActive(_ active: Bool) {
        glowActive = active
        if isUsingLiquidGlass {
            let tintAlpha: CGFloat = active ? 0.14 : 0.06
            if let glass = glassSurface {
                _ = DTSetValueForKeyCatching(
                    glass,
                    DevTypeTheme.accent.withAlphaComponent(tintAlpha),
                    "tintColor"
                )
            }
        } else {
            rimLayer.opacity = active ? 1 : 0.35
        }
    }

    func updateAudioLevel(_ level: Float) {
        if level <= 0 {
            currentAudioLevel = 0
            return
        }
        currentAudioLevel = min(max(level, 0), 1)
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        if DevTypeAccessibility.reduceMotion {
            updateBlobPath()
            return
        }
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard animationEnabled, !DevTypeAccessibility.reduceMotion else { return }
        let idleFloor: Float = glowActive ? 0.04 : 0
        let target = max(idleFloor, currentAudioLevel)
        smoothedAudioLevel = smoothedAudioLevel * 0.82 + target * 0.18
        phase += 0.045
        updateBlobPath()
    }

    override func layout() {
        super.layout()
        if contentHost.superview == glassSurface {
            contentHost.frame = bounds
        }
        updateBlobPath()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rimLayer.strokeColor = DevTypeTheme.accentBright.withAlphaComponent(0.45).cgColor
        solidBackground?.layer?.backgroundColor = DevTypeTheme.cardBackgroundSolid.cgColor
        updateBlobPath()
    }

    private func updateBlobPath() {
        let width = bounds.width
        let height = bounds.height
        guard width > 20, height > 20 else { return }

        let level: CGFloat = DevTypeAccessibility.reduceMotion
            ? 0
            : CGFloat(smoothedAudioLevel)
        let path = LiquidBlobGeometry.path(in: bounds, phase: phase, audioLevel: level)

        // Clip the whole HUD (glass + labels) to the organic silhouette.
        let clip = (layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
        clip.path = path
        layer?.mask = clip

        if let effect = visualEffectView {
            // maskImage shapes the vibrancy sample; layer mask above clips subviews.
            effect.maskImage = LiquidBlobGeometry.maskImage(path: path, size: bounds.size)
            lastMaskSize = bounds.size
        }

        if rimLayer.superlayer != nil {
            rimLayer.path = path
            rimLayer.frame = bounds
        }
    }
}

// MARK: - Fluid Harmonic Wave Visualizer View

/// Multi-harmonic sine metering. Original drawing — Apple does not ship Siri waveform assets.
final class FluidWaveVisualizerView: NSView {
    private var currentAudioLevel: Float = 0.0
    private var smoothedLevel: Float = 0.08
    private var phase: Double = 0.0
    private var displayLink: CADisplayLink?
    private var animationEnabled = false

    var isTranscribing = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        displayLink?.invalidate()
    }

    func setAnimationEnabled(_ enabled: Bool) {
        animationEnabled = enabled
        if enabled {
            startDisplayLinkIfNeeded()
        } else {
            stopDisplayLink()
            smoothedLevel = 0.08
            currentAudioLevel = 0
            needsDisplay = true
        }
    }

    func updateLevel(_ level: Float) {
        if level <= 0 {
            currentAudioLevel = 0
            return
        }
        currentAudioLevel = min(max(level, 0), 1)
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        if DevTypeAccessibility.reduceMotion {
            needsDisplay = true
            return
        }
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard animationEnabled, !DevTypeAccessibility.reduceMotion else { return }
        smoothedLevel = smoothedLevel * 0.80 + max(0.04, currentAudioLevel) * 0.20
        phase += isTranscribing ? 0.12 : 0.06
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let width = bounds.width
        let height = bounds.height
        let midY = height / 2.0
        guard width > 0, height > 0 else { return }

        let primary = DevTypeTheme.accent.withAlphaComponent(0.35)
        let bright = DevTypeTheme.accentBright.withAlphaComponent(0.60)
        let peak = DevTypeTheme.textPrimary.withAlphaComponent(0.90)

        let level = DevTypeAccessibility.reduceMotion
            ? max(0.08, CGFloat(currentAudioLevel))
            : CGFloat(smoothedLevel)

        context.saveGState()
        let waveConfigs: [(frequency: Double, amplitudeMultiplier: CGFloat, phaseOffset: Double, color: NSColor, lineWidth: CGFloat)] = [
            (1.5, 0.50, 0.0, primary, 1.5),
            (2.2, 0.75, 2.094, bright, 2.0),
            (3.0, 1.00, 4.188, peak, 2.2)
        ]
        let amplitudeBase = level * (height * 0.42)

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
