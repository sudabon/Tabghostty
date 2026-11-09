import AppKit

/// エージェントの状態 pill（spec: tab-sidebar「Agent state pill」。webtabinal `AgentStatePill.tsx` と `index.css`）。
///
/// - idle: muted、working: accent と回る印、blocked: danger。
/// - 回る印は「視差効果を減らす」が有効なら止める。
/// - アクセシビリティのラベルは「Claude Code blocked」のように、エージェントと状態を言う。
@MainActor
final class AgentStatePillView: NSView {
    var palette: ChromePalette {
        didSet { applyColors() }
    }

    var model: AgentPillModel? {
        didSet {
            guard model != oldValue else { return }
            update()
        }
    }

    /// 「視差効果を減らす」が有効か（テストで差し替える）。
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } {
        didSet { updateSpinnerAnimation() }
    }

    private let label = NSTextField(labelWithString: "")
    private let spinner = PillSpinnerView()
    private let stack: NSStackView
    private var motionObserver: NSObjectProtocol?

    init(palette: ChromePalette) {
        self.palette = palette
        stack = NSStackView(views: [spinner, label])
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 0

        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setAccessibilityElement(false)
        spinner.setAccessibilityElement(false)

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 7),
            spinner.heightAnchor.constraint(equalToConstant: 7),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let motionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(motionObserver)
            self.motionObserver = nil
        }
        if window != nil {
            motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSpinnerAnimation() }
            }
        }
        updateSpinnerAnimation()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    /// 回る印が回っているか（テスト用）。
    var isSpinnerAnimating: Bool { spinner.isAnimating }
    /// 回る印を出しているか（テスト用）。
    var showsSpinner: Bool { !spinner.isHidden }
    /// pill の文字（テスト用）。
    var text: String { label.stringValue }

    private func update() {
        isHidden = model == nil
        label.stringValue = model?.text ?? ""
        spinner.isHidden = model?.showsSpinner != true
        setAccessibilityLabel(model?.accessibilityLabel)
        toolTip = model?.accessibilityLabel
        applyColors()
        updateSpinnerAnimation()
        invalidateIntrinsicContentSize()
    }

    private func applyColors() {
        guard let kind = model?.kind else { return }
        switch kind {
        case .idle:
            label.textColor = palette.muted.nsColor
            layer?.backgroundColor = palette.muted.withAlpha(0.18).cgColor
            layer?.borderWidth = 0
        case .working:
            label.textColor = palette.accent.nsColor
            layer?.backgroundColor = palette.accent.withAlpha(0.16).cgColor
            layer?.borderWidth = 0
        case .blocked:
            label.textColor = palette.dangerText.nsColor
            layer?.backgroundColor = palette.dangerBackground.cgColor
            layer?.borderColor = palette.danger.cgColor
            layer?.borderWidth = 1
        }
        spinner.color = palette.accent
    }

    private func updateSpinnerAnimation() {
        let animate = model?.showsSpinner == true && window != nil && !reduceMotion()
        spinner.setAnimating(animate)
    }
}

/// working の回る印（7pt の輪。上側だけ濃い）。
@MainActor
private final class PillSpinnerView: NSView {
    var color = ChromePalette.dark.accent {
        didSet { applyColor() }
    }

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private(set) var isAnimating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineWidth = 1.5
            layer?.addSublayer(shape)
        }
        arc.lineCap = .round
        applyColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        let inset = bounds.insetBy(dx: 0.75, dy: 0.75)
        for shape in [track, arc] {
            shape.frame = bounds
        }
        track.path = CGPath(ellipseIn: inset, transform: nil)
        let path = CGMutablePath()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        path.addArc(center: center, radius: inset.width / 2, startAngle: .pi * 0.25, endAngle: .pi * 0.75, clockwise: false)
        arc.path = path
    }

    func setAnimating(_ animating: Bool) {
        guard animating != isAnimating else { return }
        isAnimating = animating
        if animating {
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = -2 * Double.pi
            rotation.duration = 0.8
            rotation.repeatCount = .infinity
            arc.add(rotation, forKey: "spin")
        } else {
            arc.removeAnimation(forKey: "spin")
        }
    }

    private func applyColor() {
        track.strokeColor = color.withAlpha(0.35).cgColor
        arc.strokeColor = color.cgColor
    }
}
