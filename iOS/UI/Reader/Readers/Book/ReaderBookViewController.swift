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
    private var isLoadingChapter = false
    private var isTransitioning = false
    private var lastDoublePageState: Bool?
    private var loadChapterTask: Task<Void, Never>?

    private lazy var pageViewController = makePageViewController(doublePage: false)
    private lazy var emptyPageViewController = {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .systemBackground
        return viewController
    }()
    private lazy var trailingBlankPageViewController = {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .systemBackground
        return viewController
    }()

    /// Whether we're currently showing a double-page spread (iPad landscape)
    private var isDoublePage: Bool {
        view.bounds.width > view.bounds.height && traitCollection.horizontalSizeClass == .regular
    }

    private var isShowingDoublePage: Bool {
        lastDoublePageState == true
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
        rebuildPageViewController(doublePage: false)
        add(child: pageViewController)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePageLayoutIfNeeded()
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
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.updatePageLayoutIfNeeded()
        }
    }

    // MARK: - Page Curl Setup

    private func makePageViewController(doublePage: Bool) -> UIPageViewController {
        let spineLocation: UIPageViewController.SpineLocation = doublePage ? .mid : .min
        return UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [
                .spineLocation: NSNumber(value: spineLocation.rawValue)
            ]
        )
    }

    private func updatePageLayoutIfNeeded() {
        guard !isLoadingChapter else { return }
        let doublePage = isDoublePage && !pageViewControllers.isEmpty
        guard doublePage != lastDoublePageState else { return }
        rebuildPageViewController(doublePage: doublePage)
        loadPagesAround(currentPage)
        reportCurrentPage()
    }

    private func rebuildPageViewController(doublePage: Bool) {
        let doublePage = doublePage && !pageViewControllers.isEmpty
        let viewControllers = pageViewControllers.isEmpty
            ? [emptyPageViewController]
            : currentViewControllers(for: currentPage, doublePage: doublePage)
        let oldPageViewController = pageViewController
        let wasInstalled = oldPageViewController.parent === self

        if wasInstalled {
            oldPageViewController.remove()
        }

        let newPageViewController = makePageViewController(doublePage: doublePage)
        newPageViewController.isDoubleSided = doublePage
        newPageViewController.setViewControllers(
            viewControllers,
            direction: .forward,
            animated: false
        )
        newPageViewController.delegate = self
        newPageViewController.dataSource = self
        newPageViewController.view.isUserInteractionEnabled = !isLoadingChapter
        pageViewController = newPageViewController

        isTransitioning = false
        lastDoublePageState = doublePage
        setLiveTextButtonHidden(delegate?.barsHidden ?? false)

        if wasInstalled {
            add(child: newPageViewController)
        }
    }

    // MARK: - Page Management

    private func loadPageControllers() {
        let liveTextHidden = delegate?.barsHidden ?? false
        pageViewControllers = pages.map { _ in
            let viewController = ReaderPageViewController(type: .page, delegate: delegate)
            viewController.pageView?.setLiveTextHidden(liveTextHidden)
            return viewController
        }
    }

    private func currentViewControllers(for page: Int, doublePage: Bool) -> [UIViewController] {
        guard !pageViewControllers.isEmpty else { return [] }
        let idx = max(0, min(page - 1, pageViewControllers.count - 1))
        if doublePage {
            // Provide a pair for double-page spread
            let left = pageViewControllers[idx]
            if idx + 1 < pageViewControllers.count {
                return [left, pageViewControllers[idx + 1]]
            } else {
                // Last odd page: show with empty back
                return [left, trailingBlankPageViewController]
            }
        } else {
            return [pageViewControllers[idx]]
        }
    }

    private func move(toPage page: Int, animated: Bool) {
        guard !isLoadingChapter, !isTransitioning, !pageViewControllers.isEmpty else { return }
        let clamped = max(1, min(page, pageViewControllers.count))
        let previousPage = currentPage
        let direction: UIPageViewController.NavigationDirection = clamped >= previousPage ? .forward : .reverse
        currentPage = clamped
        let vcs = currentViewControllers(for: clamped, doublePage: isShowingDoublePage)
        guard !vcs.isEmpty else { return }
        isTransitioning = animated
        pageViewController.setViewControllers(vcs, direction: direction, animated: animated) { [weak self] completed in
            guard let self, animated else { return }
            self.isTransitioning = false
            if completed {
                self.loadPagesAround(clamped)
                self.reportCurrentPage()
            } else {
                self.currentPage = previousPage
            }
        }
        if !animated {
            loadPagesAround(clamped)
            reportCurrentPage()
        }
    }

    private func loadPagesAround(_ page: Int) {
        guard !pageViewControllers.isEmpty, !pages.isEmpty else { return }
        let preloadRange = 2
        let start = max(0, page - 1 - preloadRange)
        let end = min(pageViewControllers.count - 1, page - 1 + preloadRange)
        for i in start...end {
            guard i < pages.count else { continue }
            let vc = pageViewControllers[i]
            vc.setPage(pages[i], sourceId: viewModel.source?.key ?? viewModel.manga.sourceKey)
        }
    }

    private func reportCurrentPage() {
        if isShowingDoublePage {
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
        guard !isLoadingChapter, !isTransitioning else { return }
        let step = isShowingDoublePage ? 2 : 1
        if currentPage > 1 {
            let target = max(1, currentPage - step)
            move(toPage: target, animated: true)
        } else if let prev = delegate?.getPreviousChapter() {
            delegate?.setChapter(prev)
            setChapter(prev, startPage: Int.max)
        }
    }

    func moveRight() {
        guard !isLoadingChapter, !isTransitioning else { return }
        let step = isShowingDoublePage ? 2 : 1
        let target = currentPage + step
        if target <= pageViewControllers.count {
            move(toPage: target, animated: true)
        } else if let next = delegate?.getNextChapter() {
            delegate?.setChapter(next)
            setChapter(next, startPage: 1)
        }
    }

    func sliderMoved(value: CGFloat) {
        guard !isLoadingChapter, !pageViewControllers.isEmpty else { return }
        let page = Int(round(value * CGFloat(pageViewControllers.count - 1))) + 1
        delegate?.displayPage(page)
    }

    func sliderStopped(value: CGFloat) {
        guard !isLoadingChapter, !pageViewControllers.isEmpty else { return }
        let page = Int(round(value * CGFloat(pageViewControllers.count - 1))) + 1
        move(toPage: page, animated: false)
    }

    func setChapter(_ chapter: AidokuRunner.Chapter, startPage: Int) {
        loadChapterTask?.cancel()
        self.chapter = chapter
        isLoadingChapter = true
        pageViewController.view.isUserInteractionEnabled = false
        loadChapterTask = Task { [weak self] in
            await self?.loadChapter(chapter: chapter, startPage: startPage)
        }
    }
}

// MARK: - Chapter Loading
extension ReaderBookViewController {
    private func loadChapter(chapter: AidokuRunner.Chapter, startPage: Int) async {
        await viewModel.loadPages(chapter: chapter)
        guard !Task.isCancelled, self.chapter == chapter else { return }
        pages = viewModel.pages
        delegate?.setPages(pages)
        guard parent != nil else { return }

        await MainActor.run {
            defer {
                isLoadingChapter = false
                pageViewController.view.isUserInteractionEnabled = true
                loadChapterTask = nil
            }
            loadPageControllers()
            guard !pageViewControllers.isEmpty else {
                currentPage = 1
                rebuildPageViewController(doublePage: false)
                return
            }
            let target: Int
            if startPage == Int.max {
                target = isDoublePage && pages.count.isMultiple(of: 2) ? max(1, pages.count - 1) : pages.count
            } else {
                target = max(1, min(startPage, pages.count))
            }
            currentPage = target
            rebuildPageViewController(doublePage: isDoublePage)
            loadPagesAround(target)
            reportCurrentPage()
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
        if viewController === trailingBlankPageViewController {
            return pageViewControllers.last
        }
        guard let currentIdx = pageViewControllers.firstIndex(where: { $0 === viewController }) else { return nil }
        let previousIndex = currentIdx - 1
        guard previousIndex >= 0 else { return nil }
        return pageViewControllers[previousIndex]
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard !pageViewControllers.isEmpty else { return nil }
        guard let currentIdx = pageViewControllers.firstIndex(where: { $0 === viewController }) else { return nil }
        let nextIndex = currentIdx + 1
        if nextIndex < pageViewControllers.count {
            return pageViewControllers[nextIndex]
        }
        if isShowingDoublePage && pageViewControllers.count.isMultiple(of: 2) == false {
            return trailingBlankPageViewController
        }
        return nil
    }
}

// MARK: - UIPageViewControllerDelegate
extension ReaderBookViewController: UIPageViewControllerDelegate {
    func pageViewController(
        _ pageViewController: UIPageViewController,
        willTransitionTo pendingViewControllers: [UIViewController]
    ) {
        isTransitioning = true
        setLiveTextButtonHidden(true)
        if UserDefaults.standard.bool(forKey: "Reader.hideBarsOnSwipe") {
            delegate?.hideBars()
        }
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        isTransitioning = false
        setLiveTextButtonHidden(delegate?.barsHidden ?? false)
        if completed {
            for viewController in previousViewControllers {
                (viewController as? ReaderPageViewController)?.pageView?.clearLiveTextSelection()
            }
        }
        guard completed, let vcs = pageViewController.viewControllers, let first = vcs.first else { return }
        if let idx = pageViewControllers.firstIndex(where: { $0 === first }) {
            currentPage = idx + 1
            loadPagesAround(currentPage)
            reportCurrentPage()
        }
    }
}
