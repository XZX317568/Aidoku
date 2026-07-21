//
//  ReaderToolbarView.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 8/15/22.
//

import Combine
import UIKit

class ReaderToolbarView: UIView {
    var currentPageValue: Int? {
        didSet {
            if oldValue != currentPageValue {
                let feedbackGenerator = UISelectionFeedbackGenerator()
                feedbackGenerator.selectionChanged()
            }
        }
    }
    var currentPage: Int? {
        didSet { updatePageLabels() }
    }
    var totalPages: Int? {
        didSet { updatePageLabels() }
    }
    /// Whether to show reading progress percentage
    var showProgressPercentage: Bool {
        get { UserDefaults.standard.bool(forKey: "Reader.showProgressPercentage") }
        set { UserDefaults.standard.set(newValue, forKey: "Reader.showProgressPercentage") }
    }
    /// Whether to show reading time estimate
    var showReadingTimeEstimate: Bool {
        get { UserDefaults.standard.bool(forKey: "Reader.showReadingTimeEstimate") }
        set { UserDefaults.standard.set(newValue, forKey: "Reader.showReadingTimeEstimate") }
    }

    /// Tracks page turn timestamps for speed calculation
    private var pageTurnTimestamps: [Date] = []
    /// Average seconds per page (default ~8s for manga)
    private var averageSecondsPerPage: Double = 8.0

    let sliderView = ReaderSliderView()
    private let incognitoModeLabel = UILabel()
    private let currentPageLabel = UILabel()
    private let pagesLeftLabel = UILabel()
    private let progressPercentageLabel = UILabel()

    private var cancellables: [AnyCancellable] = []

    init() {
        super.init(frame: .zero)
        configure()
        constrain()
        observe()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure() {
        incognitoModeLabel.font = .systemFont(ofSize: 10)
        incognitoModeLabel.textColor = .secondaryLabel
        incognitoModeLabel.textAlignment = .left
        incognitoModeLabel.isHidden = !UserDefaults.standard.bool(forKey: "General.incognitoMode")
        addSubview(incognitoModeLabel)

        currentPageLabel.font = .systemFont(ofSize: 10)
        currentPageLabel.textAlignment = .center
        currentPageLabel.sizeToFit()
        addSubview(currentPageLabel)

        pagesLeftLabel.font = .systemFont(ofSize: 10)
        pagesLeftLabel.textColor = .secondaryLabel
        pagesLeftLabel.textAlignment = .right
        addSubview(pagesLeftLabel)

        progressPercentageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        progressPercentageLabel.textColor = .tintColor
        progressPercentageLabel.textAlignment = .center
        progressPercentageLabel.isHidden = !showProgressPercentage
        addSubview(progressPercentageLabel)

        sliderView.semanticContentAttribute = .playback // for rtl languages
        addSubview(sliderView)
    }

    func constrain() {
        incognitoModeLabel.translatesAutoresizingMaskIntoConstraints = false
        currentPageLabel.translatesAutoresizingMaskIntoConstraints = false
        pagesLeftLabel.translatesAutoresizingMaskIntoConstraints = false
        progressPercentageLabel.translatesAutoresizingMaskIntoConstraints = false
        sliderView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            incognitoModeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            incognitoModeLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            currentPageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            currentPageLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            pagesLeftLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            pagesLeftLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            progressPercentageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            progressPercentageLabel.topAnchor.constraint(equalTo: sliderView.bottomAnchor, constant: 2),

            sliderView.heightAnchor.constraint(equalToConstant: 12),
            sliderView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            sliderView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            sliderView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])
    }

    func observe() {
        NotificationCenter.default.publisher(for: .incognitoMode)
            .sink { [weak self] _ in
                self?.incognitoModeLabel.isHidden = !UserDefaults.standard.bool(forKey: "General.incognitoMode")
            }
            .store(in: &cancellables)
    }

    // allow slider thumb to be touched outside bounds
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for subview in subviews where subview is ReaderSliderView {
            if subview.subviews.contains(where: { $0.bounds.contains(convert(point, to: $0)) }) {
                return subview
            }
        }
        return super.hitTest(point, with: event)
    }

    func displayPage(_ page: Int) {
        guard let totalPages = totalPages else {
            return
        }
        var page = page
        if page > totalPages {
            page = totalPages
        } else if page < 1 {
            page = 1
        }
        currentPageLabel.text = String(format: NSLocalizedString("%i_OF_%i", comment: ""), page, totalPages)
        currentPageValue = page
    }

    func updatePageLabels() {
        guard var currentPage = currentPage, let totalPages = totalPages else {
            currentPageLabel.text = nil
            pagesLeftLabel.text = nil
            progressPercentageLabel.text = nil
            return
        }

        if currentPage > totalPages {
            currentPage = totalPages
        } else if currentPage < 1 {
            currentPage = 1
        }
        let pagesLeft = totalPages - currentPage
        currentPageLabel.text = String(format: NSLocalizedString("%i_OF_%i", comment: ""), currentPage, totalPages)
        if pagesLeft < 1 {
            pagesLeftLabel.text = nil
        } else {
            var pagesText = pagesLeft == 1
                ? NSLocalizedString("ONE_PAGE_LEFT", comment: "")
                : String(format: NSLocalizedString("%i_PAGES_LEFT", comment: ""), pagesLeft)

            // Append time estimate if enabled
            if showReadingTimeEstimate {
                let estimatedSeconds = Double(pagesLeft) * averageSecondsPerPage
                let timeText = formatTimeEstimate(seconds: estimatedSeconds)
                pagesText += " · " + timeText
            }
            pagesLeftLabel.text = pagesText
        }
        incognitoModeLabel.text = NSLocalizedString("INCOGNITO_MODE")

        // Update progress percentage
        let progress = totalPages > 1 ? Double(currentPage - 1) / Double(totalPages - 1) * 100 : 100
        progressPercentageLabel.text = String(format: "%.0f%%", progress)
        progressPercentageLabel.isHidden = !showProgressPercentage

        // Record page turn for speed tracking
        recordPageTurn()
    }

    /// Records a page turn timestamp and recalculates reading speed
    private func recordPageTurn() {
        let now = Date()
        pageTurnTimestamps.append(now)
        // Keep only last 20 page turns for speed calculation
        if pageTurnTimestamps.count > 20 {
            pageTurnTimestamps.removeFirst(pageTurnTimestamps.count - 20)
        }
        // Calculate average time per page from recent turns
        if pageTurnTimestamps.count >= 3 {
            var totalInterval: TimeInterval = 0
            for i in 1..<pageTurnTimestamps.count {
                totalInterval += pageTurnTimestamps[i].timeIntervalSince(pageTurnTimestamps[i - 1])
            }
            let avg = totalInterval / Double(pageTurnTimestamps.count - 1)
            // Only update if reasonable (between 1s and 120s per page)
            if avg > 1 && avg < 120 {
                averageSecondsPerPage = avg
            }
        }
    }

    /// Formats seconds into a human-readable time estimate
    private func formatTimeEstimate(seconds: Double) -> String {
        let totalMinutes = Int(ceil(seconds / 60))
        if totalMinutes < 1 {
            return "<1 min"
        } else if totalMinutes == 1 {
            return "~1 min"
        } else if totalMinutes < 60 {
            return "~\(totalMinutes) min"
        } else {
            let hours = totalMinutes / 60
            let mins = totalMinutes % 60
            if mins == 0 {
                return "~\(hours)h"
            }
            return "~\(hours)h \(mins)m"
        }
    }

    func updateSliderPosition() {
        guard let currentPage = currentPage, let totalPages = totalPages else { return }
        sliderView.move(toValue: CGFloat(currentPage - 1) / max(CGFloat(totalPages - 1), 1))
    }
}
