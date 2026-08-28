import AppKit
import DevTypeSafety
import QuartzCore
import ExpanderEngine

/// State of the floating Voice HUD.
public enum VoiceHUDState: Equatable, Sendable {
    case listening(modelName: String)
    case streaming(transcript: String, modelName: String)
    case transcribing(modelName: String)
    case success(text: String, diffSegments: [TranscriptDiffEngine.Segment]? = nil)
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
    private let micImageView: NSImageView
    private let stateLabel: NSTextField
    private let transcriptLabel: NSTextField
    private var dismissWorkItem: DispatchWorkItem?
    private var currentModelName: String = "Voxtral"
    private var pendingTargetSize: CGSize?
    private var isResizeScheduled = false
    private var usesRealGlass = false

    private static let baseWidth: CGFloat = 304
    private static let baseHeight: CGFloat = 68
    private static let maxWidth: CGFloat = 500
    private static let maxHeight: CGFloat = 188

    public init() {
        let loc = LocalizationManager.shared
        self.stateLabel = DevTypeTheme.makeLabel(
            loc.s("voice.hud.status.listening"),
            font: DevTypeTheme.font(11, .medium),
            color: DevTypeTheme.textSecondary
        )
        self.stateLabel.maximumNumberOfLines = 1
        self.stateLabel.cell?.lineBreakMode = .byTruncatingTail

        self.transcriptLabel = DevTypeTheme.makeLabel(
            loc.s("voice.hud.placeholder"),
            font: DevTypeTheme.font(14.5, .regular),
            color: DevTypeTheme.textSecondary,
            wrapping: true
        )
        self.transcriptLabel.maximumNumberOfLines = 5
        self.transcriptLabel.cell?.wraps = true
        self.transcriptLabel.cell?.lineBreakMode = .byWordWrapping
        self.blobContainer = LiquidGlassBlobHUDView()

        let micIcon = DevTypeTheme.tintedSymbol(
            "mic.fill",
            size: 11,
            weight: .medium,
            color: DevTypeTheme.textSecondary
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
        rootStack.spacing = 5
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        blobContainer.contentHost.addSubview(rootStack)

        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 5
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        headerStack.addArrangedSubview(micImageView)
        headerStack.addArrangedSubview(stateLabel)
        headerStack.addArrangedSubview(spacer)
        headerStack.addArrangedSubview(fluidWaveView)

        transcriptLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        transcriptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        fluidWaveView.translatesAutoresizingMaskIntoConstraints = false
        fluidWaveView.widthAnchor.constraint(equalToConstant: 44).isActive = true
        fluidWaveView.heightAnchor.constraint(equalToConstant: 14).isActive = true

        rootStack.addArrangedSubview(headerStack)
        rootStack.addArrangedSubview(transcriptLabel)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: blobContainer.contentHost.topAnchor, constant: 11),
            rootStack.leadingAnchor.constraint(equalTo: blobContainer.contentHost.leadingAnchor, constant: 18),
            rootStack.trailingAnchor.constraint(equalTo: blobContainer.contentHost.trailingAnchor, constant: -18),
            rootStack.bottomAnchor.constraint(equalTo: blobContainer.contentHost.bottomAnchor, constant: -10),
            headerStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            transcriptLabel.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])
    }

    // MARK: - Public State Controls

    /// Updates the HUD state and positions it on screen.
    public func updateState(_ state: VoiceHUDState) {
        dismissWorkItem?.cancel()
        let loc = LocalizationManager.shared

        switch state {
        case .listening(let modelName):
            currentModelName = modelName
            updateStatus(loc.s("voice.hud.status.listening"), color: DevTypeTheme.accent)
            transcriptLabel.stringValue = loc.s("voice.hud.placeholder")
            transcriptLabel.textColor = DevTypeTheme.textSecondary
            fluidWaveView.isTranscribing = false
            blobContainer.setActive(true)
            scheduleSize(forText: "")
            updateAccessibility(status: stateLabel.stringValue, transcript: transcriptLabel.stringValue)
            showOnScreen()

        case .streaming(let transcript, let modelName):
            currentModelName = modelName
            updateStatus(loc.s("voice.hud.status.live"), color: DevTypeTheme.accent)
            let prompt = loc.s("voice.hud.listening")
            transcriptLabel.stringValue = transcript.isEmpty ? prompt : transcript
            transcriptLabel.textColor = DevTypeTheme.textPrimary
            fluidWaveView.isTranscribing = false
            blobContainer.setActive(true)
            scheduleSize(forText: transcript)
            updateAccessibility(status: stateLabel.stringValue, transcript: transcriptLabel.stringValue)
            showOnScreen()

        case .transcribing(let modelName):
            currentModelName = modelName
            updateStatus(loc.s("voice.hud.status.polishing"), color: DevTypeTheme.accent)
            fluidWaveView.isTranscribing = true
            updateAudioLevel(0)
            blobContainer.setActive(true)
            updateAccessibility(status: stateLabel.stringValue, transcript: transcriptLabel.stringValue)
            showOnScreen()

        case .success(let text, let diffSegments):
            updateStatus(loc.s("voice.hud.status.inserted"), color: DevTypeTheme.statusGreen)
            if let diffSegments, diffSegments.contains(where: { $0.isCut }) {
                let attrStr = NSMutableAttributedString()
                for seg in diffSegments {
                    if seg.isCut {
                        let cutAttrs: [NSAttributedString.Key: Any] = [
                            .font: DevTypeTheme.font(14.5, .regular),
                            .foregroundColor: DevTypeTheme.textTertiary,
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .strikethroughColor: DevTypeTheme.statusOrange
                        ]
                        attrStr.append(NSAttributedString(string: seg.text + " ", attributes: cutAttrs))
                    } else {
                        let keptAttrs: [NSAttributedString.Key: Any] = [
                            .font: DevTypeTheme.font(14.5, .regular),
                            .foregroundColor: DevTypeTheme.textPrimary
                        ]
                        attrStr.append(NSAttributedString(string: seg.text + " ", attributes: keptAttrs))
                    }
                }
                transcriptLabel.attributedStringValue = attrStr
            } else {
                let preview = text.count > 100 ? String(text.prefix(97)) + "…" : text
                transcriptLabel.stringValue = preview
                transcriptLabel.textColor = DevTypeTheme.textPrimary
            }
            fluidWaveView.isTranscribing = false
            updateAudioLevel(0)
            blobContainer.setActive(false)
            scheduleSize(forText: text)
            updateAccessibility(status: stateLabel.stringValue, transcript: text)
            showOnScreen()
            scheduleAutoDismiss(after: VoiceHUDPresentationTiming.successHoldDuration)

        case .error(let message):
            updateStatus(loc.s("voice.hud.status.failed"), color: DevTypeTheme.statusOrange)
            transcriptLabel.stringValue = message
            transcriptLabel.textColor = DevTypeTheme.textPrimary
            fluidWaveView.isTranscribing = false
            updateAudioLevel(0)
            blobContainer.setActive(false)
            scheduleSize(forText: message)
            updateAccessibility(status: stateLabel.stringValue, transcript: message)
            showOnScreen()
            scheduleAutoDismiss(after: VoiceHUDPresentationTiming.errorHoldDuration)
        }
    }

    private func updateStatus(_ text: String, color: NSColor) {
        stateLabel.stringValue = text
        stateLabel.textColor = color
        micImageView.contentTintColor = color
        fluidWaveView.tintColor = color
    }

    private func updateAccessibility(status: String, transcript: String) {
        setAccessibilityLabel(status)
        setAccessibilityValue(transcript)
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
        let font = DevTypeTheme.font(14.5, .regular)
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
            context.duration = 0.26
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.82, 0.20, 1.0)
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
                    context.duration = VoiceHUDPresentationTiming.fadeInDuration
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
            context.duration = VoiceHUDPresentationTiming.fadeOutDuration
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
    private var lastGlassCornerRadius: CGFloat = -1

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
        // NSGlassEffectView.Style.regular is raw value 0. This HUD carries live
        // text over arbitrary desktop content, where regular glass preserves
        // legibility better than the clear media-overlay variant. Runtime KVC
        // keeps the target buildable with pre-macOS-26 SDKs used by CI.
        _ = DTSetValueForKeyCatching(glass, NSNumber(value: 0), "style")
        let tint = DevTypeTheme.accent.withAlphaComponent(0.09)
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
        rimLayer.lineWidth = DevTypeAccessibility.increaseContrast ? 1.2 : 0.7
        rimLayer.strokeColor = DevTypeTheme.accent.withAlphaComponent(
            DevTypeAccessibility.increaseContrast ? 0.48 : 0.30
        ).cgColor
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
            let tintAlpha: CGFloat = active ? 0.10 : 0.04
            if let glass = glassSurface {
                _ = DTSetValueForKeyCatching(
                    glass,
                    DevTypeTheme.accent.withAlphaComponent(tintAlpha),
                    "tintColor"
                )
            }
        } else {
            rimLayer.opacity = active ? 1.0 : 0.55
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
        updateGlassCornerRadius()
        updateBlobPath()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rimLayer.strokeColor = DevTypeTheme.accent.withAlphaComponent(
            DevTypeAccessibility.increaseContrast ? 0.48 : 0.30
        ).cgColor
        solidBackground?.layer?.backgroundColor = DevTypeTheme.cardBackgroundSolid.cgColor
        updateBlobPath()
    }

    private func updateGlassCornerRadius() {
        guard let glass = glassSurface else { return }
        let radius = bounds.height / 2
        guard abs(radius - lastGlassCornerRadius) > 0.5 else { return }
        _ = DTSetValueForKeyCatching(glass, NSNumber(value: radius), "cornerRadius")
        lastGlassCornerRadius = radius
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
        }

        if rimLayer.superlayer != nil {
            rimLayer.path = path
            rimLayer.frame = bounds
        }
    }
}

// MARK: - Fluid Harmonic Wave Visualizer View

/// Compact harmonic metering. Original drawing — Apple does not ship Siri waveform assets.
final class FluidWaveVisualizerView: NSView {
    private var currentAudioLevel: Float = 0.0
    private var smoothedLevel: Float = 0.04
    private var phase: Double = 0.0
    private var displayLink: CADisplayLink?
    private var animationEnabled = false

    var tintColor: NSColor = DevTypeTheme.textSecondary {
        didSet { needsDisplay = true }
    }

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
            smoothedLevel = 0.04
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
        smoothedLevel = smoothedLevel * 0.84 + max(0.03, currentAudioLevel) * 0.16
        phase += isTranscribing ? 0.075 : 0.045
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let width = bounds.width
        let height = bounds.height
        let midY = height / 2.0
        guard width > 0, height > 0 else { return }

        let level = DevTypeAccessibility.reduceMotion
            ? max(0.04, CGFloat(currentAudioLevel))
            : CGFloat(smoothedLevel)

        context.saveGState()
        let waveConfigs: [(frequency: Double, amplitudeMultiplier: CGFloat, phaseOffset: Double, color: NSColor, lineWidth: CGFloat)] = [
            (1.35, 0.62, 0.0, tintColor.withAlphaComponent(0.42), 1.25),
            (2.10, 1.00, 2.20, tintColor.withAlphaComponent(0.82), 1.55)
        ]
        let amplitudeBase = level * (height * 0.38)

        for config in waveConfigs {
            let path = CGMutablePath()
            let amp = amplitudeBase * config.amplitudeMultiplier
            var isFirst = true
            let step: CGFloat = 2.0
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
