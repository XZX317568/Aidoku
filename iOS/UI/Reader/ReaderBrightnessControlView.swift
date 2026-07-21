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

    private var initialBrightness: CGFloat = 0
    private var isAdjusting = false
    private var hideTimer: Timer?

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

        // Indicator container
        brightnessIndicator.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        brightnessIndicator.layer.cornerRadius = 12
        brightnessIndicator.clipsToBounds = true
        brightnessIndicator.alpha = 0
        brightnessIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(brightnessIndicator)

        // Sun icon
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
    }

    private var brightnessFillHeightConstraint: NSLayoutConstraint?

    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)
        // Only activate on left 25% of screen
        if location.x < bounds.width * 0.25 {
            isAdjusting = true
            initialBrightness = UIScreen.main.brightness
            showIndicator()
        } else {
            super.touchesBegan(touches, with: event)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isAdjusting, let touch = touches.first else {
            super.touchesMoved(touches, with: event)
            return
        }
        let translation = touch.location(in: self).y - touch.previousLocation(in: self).y
        let sensitivity: CGFloat = 0.005
        let newBrightness = max(0.01, min(1.0, UIScreen.main.brightness - translation * sensitivity))
        UIScreen.main.brightness = newBrightness
        updateFill()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isAdjusting {
            isAdjusting = false
            scheduleHide()
        } else {
            super.touchesEnded(touches, with: event)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isAdjusting {
            isAdjusting = false
            scheduleHide()
        } else {
            super.touchesCancelled(touches, with: event)
        }
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
