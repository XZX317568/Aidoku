//
//  ReaderBookViewController.swift
//  Aidoku (iOS)
//
//  Book-style reading mode with realistic page curl animation.
//  On iPad landscape: shows two pages side by side (like a real manga book).
//  On portrait/iPhone: shows single page with curl animation.
//

import AidokuRunner
import UIKit

class ReaderBookViewController: BaseObservingViewController, ReaderReaderDelegate {

    let viewModel: ReaderPagedViewModel

    weak var delegate: ReaderHoldingDelegate?

    var chapter: AidokuRunner.Chapter?
    var readingMode: ReadingMode = .book

    private var pages: [Page] = []
    private var pageViewControllers: [ReaderPageViewController] = []
    private var currentPage = 1
    private var isTransitioning = false
    private var lastDoublePageState: Bool?

    private lazy var pageViewController = makePageViewController()

    /// Whether we're currently showing a double-page spread (iPad landscape)
    private var isDoublePage: Bool {
        view.bounds.width > view.bounds.height && traitCollection.horizontalSizeClass == .regular
    }

    init(source: AidokuRunner.Source?, manga: AidokuRunner.Manga) {
        self.viewModel = ReaderPagedViewModel(source: source, manga: manga)
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func configure() {
        pageViewController.delegate = self
        pageViewController.dataSource = self
        add(child: pageViewController)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Update spine after view has a valid frame
        updateSpineLocation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Only re-evaluate when the double-page state actually changes
        let current = isDoublePage
        if current != lastDoublePageState {
            updateSpineLocation()
        }
    }

    override func observe() {
        addObserver(forName: .readerShowingBars) { [weak self] _ in
            self?.setLiveTextButtonHidden(false)
        }
        addObserver(forName: .readerHidingBars) { [weak self] _ in
            self?.setLiveTextButtonHidden(true)
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.updateSpineLocation()
        })
    }

    // MARK: - Page Curl Setup

    private func makePageViewController() -> UIPageViewController {
        UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: nil
        )
    }

    private func updateSpineLocation() {
        let doublePage = isDoublePage
        lastDoublePageState = doublePage
        pageViewController.isDoubleSided = doublePage

        // Set the current page(s) with the new spine location
        let currentVCs = currentViewControllers(for: currentPage)
        pageViewController.setViewControllers(
            currentVCs,
            direction: .forward,
            animated: false
        )

        // Use a concrete UIInterfaceOrientation value
        let orientation: UIInterfaceOrientation = view.bounds.width > view.bounds.height ? .landscapeLeft : .portrait
        pageViewController.delegate?.pageViewController?(
            pageViewController,
            spineLocationFor: orientation
        )
    }

    // MARK: - Page Management

    private func loadPageControllers() {
        pageViewControllers = pages.enumerated().map { _, _ in
            ReaderPageViewController(type: .page, delegate: delegate)
        }
    }

    private func currentViewControllers(for page: Int) -> [UIViewController] {
        let idx = max(0, min(page - 1, pageViewControllers.count - 1))
        if isDoublePage {
            // Provide a pair for double-page spread
            let left = pageViewControllers[idx]
            if idx + 1 < pageViewControllers.count {
                return [left, pageViewControllers[idx + 1]]
            } else {
                // Last odd page: show with empty back
                let empty = UIViewController()
                empty.view.backgroundColor = .systemBackground
                return [left, empty]
            }
        } else {
            return [pageViewControllers[idx]]
        }
    }

    private func move(toPage page: Int, animated: Bool) {
        guard !pageViewControllers.isEmpty else { return }
        let clamped = max(1, min(page, pageViewControllers.count))
        // compute direction based on currentPage before updating it
        let direction: UIPageViewController.NavigationDirection = clamped >= currentPage ? .forward : .reverse
        currentPage = clamped
        let vcs = currentViewControllers(for: clamped)
        pageViewController.setViewControllers(vcs, direction: direction, animated: animated)
        loadPagesAround(clamped)
        reportCurrentPage()
    }

    private func loadPagesAround(_ page: Int) {
        let preloadRange = 2
        let start = max(0, page - 1 - preloadRange)
        let end = min(pageViewControllers.count - 1, page - 1 + preloadRange)
        for i in start...end {
            guard i < pages.count else { continue }
            let vc = pageViewControllers[i]
            if vc.pageView?.imageView.image == nil {
                Task {
                    _ = await vc.pageView?.setPage(pages[i], sourceId: viewModel.source?.key)
                }
            }
        }
    }

    private func reportCurrentPage() {
        if isDoublePage {
            let left = currentPage
            let right = min(currentPage + 1, pages.count)
            delegate?.setCurrentPages(left...right)
        } else {
            delegate?.setCurrentPage(currentPage, position: nil)
        }
    }

    private func setLiveTextButtonHidden(_ hidden: Bool) {
        for vc in pageViewControllers {
            vc.pageView?.setLiveTextHidden(hidden)
        }
    }

    // MARK: - ReaderReaderDelegate

    func moveLeft() {
        guard !isTransitioning else { return }
        let step = isDoublePage ? 2 : 1
        let target = currentPage - step
        if target >= 1 {
            move(toPage: target, animated: true)
        } else if let prev = delegate?.getPreviousChapter() {
            setChapter(prev, startPage: Int.max)
        }
    }

    func moveRight() {
        guard !isTransitioning else { return }
        let step = isDoublePage ? 2 : 1
        let target = currentPage + step
        if target <= pageViewControllers.count {
            move(toPage: target, animated: true)
        } else if let next = delegate?.getNextChapter() {
            setChapter(next, startPage: 1)
        }
    }

    func sliderMoved(value: CGFloat) {
        let page = max(1, min(Int(value * CGFloat(pageViewControllers.count)) + 1, pageViewControllers.count))
        move(toPage: page, animated: false)
    }

    func sliderStopped(value: CGFloat) {
        sliderMoved(value: value)
    }

    func setChapter(_ chapter: AidokuRunner.Chapter, startPage: Int) {
        self.chapter = chapter
        Task {
            await loadChapter(startPage: startPage)
        }
    }
}

// MARK: - Chapter Loading
extension ReaderBookViewController {
    func loadChapter(startPage: Int) async {
        guard let chapter else { return }
        await viewModel.loadPages(chapter: chapter)
        pages = viewModel.pages
        delegate?.setPages(pages)

        await MainActor.run {
            loadPageControllers()
            let target = startPage == Int.max ? pages.count : max(1, min(startPage, pages.count))
            move(toPage: target, animated: false)
        }
    }
}

// MARK: - UIPageViewControllerDataSource
extension ReaderBookViewController: UIPageViewControllerDataSource {
    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard !pageViewControllers.isEmpty else { return nil }
        let idx = pageViewControllers.firstIndex(where: { $0 === viewController })
            ?? pageViewControllers.firstIndex(where: { $0 === (viewController as? ReaderDoublePageViewController)?.firstPageController })

        if isDoublePage {
            // In double-page mode, go back by 2
            guard let currentIdx = idx ?? currentIndexFromViewControllers(pageViewController.viewControllers) else { return nil }
            let prevIdx = currentIdx - 2
            guard prevIdx >= 0 else { return nil }
            let left = pageViewControllers[prevIdx]
            let right = pageViewControllers[prevIdx + 1]
            // Return the left page; the delegate will provide the pair
            return left
        } else {
            guard let currentIdx = idx else { return nil }
            let prevIdx = currentIdx - 1
            guard prevIdx >= 0 else { return nil }
            return pageViewControllers[prevIdx]
        }
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard !pageViewControllers.isEmpty else { return nil }
        let idx = pageViewControllers.firstIndex(where: { $0 === viewController })
            ?? pageViewControllers.firstIndex(where: { $0 === (viewController as? ReaderDoublePageViewController)?.firstPageController })

        if isDoublePage {
            guard let currentIdx = idx ?? currentIndexFromViewControllers(pageViewController.viewControllers) else { return nil }
            let nextIdx = currentIdx + 2
            guard nextIdx < pageViewControllers.count else { return nil }
            return pageViewControllers[nextIdx]
        } else {
            guard let currentIdx = idx else { return nil }
            let nextIdx = currentIdx + 1
            guard nextIdx < pageViewControllers.count else { return nil }
            return pageViewControllers[nextIdx]
        }
    }

    private func currentIndexFromViewControllers(_ vcs: [UIViewController]?) -> Int? {
        guard let first = vcs?.first else { return nil }
        return pageViewControllers.firstIndex(where: { $0 === first })
    }
}

// MARK: - UIPageViewControllerDelegate
extension ReaderBookViewController: UIPageViewControllerDelegate {
    func pageViewController(
        _ pageViewController: UIPageViewController,
        spineLocationFor orientation: UIInterfaceOrientation
    ) -> UIPageViewController.SpineLocation {
        let isLandscape = orientation.isLandscape && traitCollection.horizontalSizeClass == .regular
        pageViewController.isDoubleSided = isLandscape
        return isLandscape ? .mid : .min
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        willTransitionTo pendingViewControllers: [UIViewController]
    ) {
        isTransitioning = true
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        isTransitioning = false
        guard completed, let vcs = pageViewController.viewControllers, let first = vcs.first else { return }
        if let idx = pageViewControllers.firstIndex(where: { $0 === first }) {
            currentPage = idx + 1
            loadPagesAround(currentPage)
            reportCurrentPage()
        }
    }
}
