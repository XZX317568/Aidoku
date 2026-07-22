//
//  ReaderBrightnessControlView.swift
//  Aidoku (iOS)
//
//  Brightness adjustment gesture overlay for the reader.
//  Swipe up/down on the left edge to adjust screen brightness.
//

import UIKit

class ReaderBrightnessControlView: UIView {
    private let brightnessIndicator = UIView()
    private let brightnessIcon = UIImageView()
    private let brightnessBar = UIView()
    private let brightnessFill = UIView()

    private var isAdjusting = false
    private var hideTimer: Timer?
    private var brightnessFillHeightConstraint: NSLayoutConstraint?

    private let barHeight: CGFloat = 120
    private let barWidth: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        backgroundColor = .clear
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = false

        // Indicator container
        brightnessIndicator.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        brightnessIndicator.layer.cornerRadius = 12
        brightnessIndicator.clipsToBounds = true
        brightnessIndicator.alpha = 0
        brightnessIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(brightnessIndicator)

        // Icon
        brightnessIcon.image = UIImage(systemName: "sun.max.fill")
        brightnessIcon.tintColor = .white
        brightnessIcon.contentMode = .scaleAspectFit
        brightnessIcon.translatesAutoresizingMaskIntoConstraints = false
        brightnessIndicator.addSubview(brightnessIcon)

        // Bar track
        brightnessBar.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        brightnessBar.layer.cornerRadius = barWidth / 2
        brightnessBar.translatesAutoresizingMaskIntoConstraints = false
        brightnessIndicator.addSubview(brightnessBar)

        // Bar fill
        brightnessFill.backgroundColor = .white
        brightnessFill.layer.cornerRadius = barWidth / 2
        brightnessFill.translatesAutoresizingMaskIntoConstraints = false
        brightnessBar.addSubview(brightnessFill)

        NSLayoutConstraint.activate([
            brightnessIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            brightnessIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            brightnessIndicator.widthAnchor.constraint(equalToConstant: 40),
            brightnessIndicator.heightAnchor.constraint(equalToConstant: 160),

            brightnessIcon.topAnchor.constraint(equalTo: brightnessIndicator.topAnchor, constant: 12),
            brightnessIcon.centerXAnchor.constraint(equalTo: brightnessIndicator.centerXAnchor),
            brightnessIcon.widthAnchor.constraint(equalToConstant: 16),
            brightnessIcon.heightAnchor.constraint(equalToConstant: 16),

            brightnessBar.topAnchor.constraint(equalTo: brightnessIcon.bottomAnchor, constant: 10),
            brightnessBar.bottomAnchor.constraint(equalTo: brightnessIndicator.bottomAnchor, constant: -12),
            brightnessBar.centerXAnchor.constraint(equalTo: brightnessIndicator.centerXAnchor),
            brightnessBar.widthAnchor.constraint(equalToConstant: barWidth),

            brightnessFill.bottomAnchor.constraint(equalTo: brightnessBar.bottomAnchor),
            brightnessFill.centerXAnchor.constraint(equalTo: brightnessBar.centerXAnchor),
            brightnessFill.widthAnchor.constraint(equalToConstant: barWidth)
        ])

        brightnessFillHeightConstraint = brightnessFill.heightAnchor.constraint(
            equalToConstant: barHeight * CGFloat(UIScreen.main.brightness)
        )
        brightnessFillHeightConstraint?.isActive = true

        // This view is already constrained to the left edge of the reader.
        // Use a vertical pan so horizontal page-turn gestures can still compete.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    // MARK: - Gesture Handling

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            isAdjusting = true
            showIndicator()
        case .changed:
            guard isAdjusting else { return }
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            let sensitivity: CGFloat = 0.005
            let newBrightness = max(0.01, min(1.0, UIScreen.main.brightness - translation.y * sensitivity))
            UIScreen.main.brightness = newBrightness
            updateFill()
        case .ended, .cancelled, .failed:
            if isAdjusting {
                isAdjusting = false
                scheduleHide()
            }
        default:
            break
        }
    }

    // Prefer vertical movement so page-turn / tap zones remain usable.
    // Must live in the class body (Swift disallows overrides in extensions).
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let velocity = pan.velocity(in: self)
        if abs(velocity.x) > 0 || abs(velocity.y) > 0 {
            return abs(velocity.y) > abs(velocity.x)
        }
        // Slow presses may report zero velocity; fall back to translation.
        let translation = pan.translation(in: self)
        return abs(translation.y) >= abs(translation.x)
    }

    // MARK: - UI Updates

    private func showIndicator() {
        hideTimer?.invalidate()
        hideTimer = nil
        updateFill()
        UIView.animate(withDuration: 0.2) {
            self.brightnessIndicator.alpha = 1
        }
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            UIView.animate(withDuration: 0.3) {
                self?.brightnessIndicator.alpha = 0
            }
        }
    }

    private func updateFill() {
        let fillHeight = barHeight * CGFloat(UIScreen.main.brightness)
        brightnessFillHeightConstraint?.constant = fillHeight
        layoutIfNeeded()
    }
}

extension ReaderBrightnessControlView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}