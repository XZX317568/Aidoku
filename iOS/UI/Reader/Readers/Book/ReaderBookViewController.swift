//
//  ReaderBookViewController.swift
//  Aidoku (iOS)
//
//  Book-style reading mode with realistic page curl animation.
//  On iPad landscape: shows two pages side by side (like a real manga book).
//  On portrait/iPhone: shows single page with curl animation.
//  Direction follows the manga viewer (RTL for typical manga, LTR for comics).
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
    private lazy var pagesToPreload = max(1, UserDefaults.standard.integer(forKey: "Reader.pagesToPreload"))

    private lazy var pageViewController = makePageViewController(doublePage: false)
    private lazy var emptyPageViewController = makeBlankPageViewController()
    private lazy var trailingBlankPageViewController = makeBlankPageViewController()

    /// Whether the content reads right-to-left (typical manga).
    private var isRTL: Bool {
        switch viewModel.manga.viewer {
            case .leftToRight: return false
            case .rightToLeft: return true
            default: return true
        }
    }

    /// Whether we're currently showing a double-page spread (iPad landscape)
    private var isDoublePage: Bool {
        // bounds can be zero during early layout; treat as single page until valid.
        guard view.bounds.width > 0, view.bounds.height > 0 else { return false }
        return view.bounds.width > view.bounds.height && traitCollection.horizontalSizeClass == .regular
    }

    private var isShowingDoublePage: Bool {
        lastDoublePageState == true
    }

    private var pageStep: Int {
        isShowingDoublePage ? 2 : 1
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
        installPageViewController(pageViewController)
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
        addObserver(forName: "Reader.pagesToPreload") { [weak self] notification in
            self?.pagesToPreload = max(
                1,
                notification.object as? Int
                    ?? UserDefaults.standard.integer(forKey: "Reader.pagesToPreload")
            )
            if let self, !self.pageViewControllers.isEmpty {
                self.loadPagesAround(self.currentPage)
            }
        }
        addObserver(forName: UIApplication.didReceiveMemoryWarningNotification.rawValue) { [weak self] _ in
            self?.handleMemoryWarning()
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.updatePageLayoutIfNeeded()
        }
    }

    // MARK: - Page Curl Setup

    private func makeBlankPageViewController() -> UIViewController {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .systemBackground
        return viewController
    }

    private func makePageViewController(doublePage: Bool) -> UIPageViewController {
        // Single page always uses .min (reliable). Double page uses .mid.
        // RTL interaction is flipped with semanticContentAttribute instead of spine .max.
        let spineLocation: UIPageViewController.SpineLocation = doublePage ? .mid : .min
        let controller = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [
                .spineLocation: NSNumber(value: spineLocation.rawValue)
            ]
        )
        controller.view.semanticContentAttribute = isRTL ? .forceRightToLeft : .forceLeftToRight
        return controller
    }

    private func installPageViewController(_ controller: UIPageViewController) {
        add(child: controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func updatePageLayoutIfNeeded() {
        guard !isLoadingChapter, !isTransitioning else { return }
        let doublePage = isDoublePage && !pageViewControllers.isEmpty
        guard doublePage != lastDoublePageState else { return }
        currentPage = alignedPage(currentPage, doublePage: doublePage)
        rebuildPageViewController(doublePage: doublePage)
        loadPagesAround(currentPage)
        reportCurrentPage()
    }

    private func viewControllersForDisplay(page: Int, doublePage: Bool) -> [UIViewController] {
        if pageViewControllers.isEmpty {
            // Mid-spine requires two controllers; min-spine requires one.
            return doublePage
                ? [emptyPageViewController, trailingBlankPageViewController]
                : [emptyPageViewController]
        }

        let startPage = alignedPage(page, doublePage: doublePage)
        let idx = startPage - 1
        guard idx >= 0, idx < pageViewControllers.count else {
            return doublePage
                ? [emptyPageViewController, trailingBlankPageViewController]
                : [emptyPageViewController]
        }

        if doublePage {
            let first = pageViewControllers[idx]
            let second: UIViewController
            if idx + 1 < pageViewControllers.count {
                second = pageViewControllers[idx + 1]
            } else {
                second = trailingBlankPageViewController
            }
            // With forceRightToLeft, array order is still [leading, trailing];
            // the semantic attribute places lower page on the right visually.
            return [first, second]
        } else {
            return [pageViewControllers[idx]]
        }
    }

    private func rebuildPageViewController(doublePage: Bool) {
        let doublePage = doublePage && !pageViewControllers.isEmpty
        let viewControllers = viewControllersForDisplay(page: currentPage, doublePage: doublePage)

        // Detach reused controllers before the old PVC is removed / new PVC attaches them.
        // Otherwise UIKit can crash with "child view controllers can only have one parent"
        // or "The number of view controllers provided (N) doesn't match the number required".
        detachFromParent(pageViewControllers)
        detachFromParent([emptyPageViewController, trailingBlankPageViewController])
        detachFromParent(viewControllers)

        let oldPageViewController = pageViewController
        let wasInstalled = oldPageViewController.parent === self
        if wasInstalled {
            oldPageViewController.delegate = nil
            oldPageViewController.dataSource = nil
            oldPageViewController.remove()
        }

        let newPageViewController = makePageViewController(doublePage: doublePage)
        newPageViewController.isDoubleSided = doublePage

        // Final detach immediately before attach.
        detachFromParent(viewControllers)

        guard !viewControllers.isEmpty else {
            pageViewController = newPageViewController
            lastDoublePageState = false
            if wasInstalled {
                installPageViewController(newPageViewController)
            }
            return
        }

        // UIPageViewController asserts if count doesn't match spine:
        // mid => 2, min/max => 1
        let expectedCount = doublePage ? 2 : 1
        let controllersToSet: [UIViewController]
        if viewControllers.count == expectedCount {
            controllersToSet = viewControllers
        } else if doublePage {
            if let first = viewControllers.first {
                controllersToSet = [first, trailingBlankPageViewController]
            } else {
                controllersToSet = [emptyPageViewController, trailingBlankPageViewController]
            }
        } else {
            controllersToSet = viewControllers.first.map { [$0] } ?? [emptyPageViewController]
        }

        detachFromParent(controllersToSet)
        newPageViewController.setViewControllers(
            controllersToSet,
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
            installPageViewController(newPageViewController)
        }
    }

    /// Detach controllers from any parent other than `allowedParent`.
    /// When moving pages within the same UIPageViewController, leave them attached
    /// so UIKit can reuse them without a parent-transition race.
    private func detachFromParent(
        _ viewControllers: [UIViewController],
        allowedParent: UIViewController? = nil
    ) {
        for viewController in viewControllers {
            if let parent = viewController.parent {
                if parent === allowedParent { continue }
                viewController.willMove(toParent: nil)
                viewController.view.removeFromSuperview()
                viewController.removeFromParent()
            } else if viewController.view.superview != nil {
                viewController.view.removeFromSuperview()
            }
        }
    }

    // MARK: - Page Management

    private func loadPageControllers() {
        detachFromParent(pageViewControllers)
        let liveTextHidden = delegate?.barsHidden ?? false
        pageViewControllers = pages.map { _ in
            let viewController = ReaderPageViewController(type: .page, delegate: delegate)
            viewController.pageView?.setLiveTextHidden(liveTextHidden)
            return viewController
        }
    }

    /// Snap to the first page of a double-page spread (1-based, odd pages).
    private func alignedPage(_ page: Int, doublePage: Bool? = nil) -> Int {
        let count = pageViewControllers.count
        guard count > 0 else { return 1 }
        let useDouble = doublePage ?? isShowingDoublePage
        let clamped = max(1, min(page, count))
        guard useDouble else { return clamped }
        return clamped % 2 == 0 ? clamped - 1 : clamped
    }

    private func move(toPage page: Int, animated: Bool) {
        guard !isLoadingChapter, !isTransitioning, !pageViewControllers.isEmpty else { return }
        let clamped = alignedPage(page)
        let previousPage = currentPage
        let direction: UIPageViewController.NavigationDirection =
            clamped >= previousPage ? .forward : .reverse
        currentPage = clamped

        let expectedCount = isShowingDoublePage ? 2 : 1
        var vcs = viewControllersForDisplay(page: clamped, doublePage: isShowingDoublePage)
        if vcs.count != expectedCount {
            if isShowingDoublePage {
                if let first = vcs.first {
                    vcs = [first, trailingBlankPageViewController]
                } else {
                    return
                }
            } else if let first = vcs.first {
                vcs = [first]
            } else {
                return
            }
        }

        // Keep controllers already parented by the active page curl controller.
        detachFromParent(vcs, allowedParent: pageViewController)

        let shouldAnimate = animated && UserDefaults.standard.bool(forKey: "Reader.animatePageTransitions")
        isTransitioning = shouldAnimate
        pageViewController.setViewControllers(vcs, direction: direction, animated: shouldAnimate) { [weak self] completed in
            guard let self else { return }
            if shouldAnimate {
                self.isTransitioning = false
            }
            if completed {
                self.loadPagesAround(clamped)
                self.reportCurrentPage()
            } else if shouldAnimate {
                self.currentPage = previousPage
            }
        }
        if !shouldAnimate {
            isTransitioning = false
            loadPagesAround(clamped)
            reportCurrentPage()
        }
    }

    private func loadPagesAround(_ page: Int) {
        guard !pageViewControllers.isEmpty, !pages.isEmpty else { return }
        let preloadRange = max(1, pagesToPreload)
        let start = max(0, page - 1 - preloadRange)
        let end = min(pageViewControllers.count - 1, page - 1 + preloadRange + (isShowingDoublePage ? 1 : 0))
        guard start <= end else { return }
        for i in start...end {
            guard i < pages.count, i < pageViewControllers.count else { continue }
            pageViewControllers[i].setPage(
                pages[i],
                sourceId: viewModel.source?.key ?? viewModel.manga.sourceKey
            )
        }
    }

    private func handleMemoryWarning() {
        guard !pageViewControllers.isEmpty else { return }
        let preloadRange = max(1, pagesToPreload)
        let start = max(0, currentPage - 1 - preloadRange)
        let end = min(pageViewControllers.count - 1, currentPage - 1 + preloadRange + (isShowingDoublePage ? 1 : 0))
        guard start <= end else { return }
        let safeRange = start...end
        for (idx, controller) in pageViewControllers.enumerated() where !safeRange.contains(idx) {
            controller.clearPage()
        }
    }

    private func reportCurrentPage() {
        guard !pages.isEmpty else { return }
        if isShowingDoublePage {
            let first = max(1, min(currentPage, pages.count))
            let second = min(first + 1, pages.count)
            delegate?.setCurrentPages(first...second)
        } else {
            let page = max(1, min(currentPage, pages.count))
            delegate?.setCurrentPage(page, position: nil)
        }
    }

    private func setLiveTextButtonHidden(_ hidden: Bool) {
        for vc in pageViewControllers {
            vc.pageView?.setLiveTextHidden(hidden)
        }
    }

    private func pageIndex(of viewController: UIViewController) -> Int? {
        if viewController === trailingBlankPageViewController || viewController === emptyPageViewController {
            return pageViewControllers.isEmpty ? nil : pageViewControllers.count - 1
        }
        return pageViewControllers.firstIndex(where: { $0 === viewController })
    }

    /// Content-order neighbor: negative offset = earlier pages, positive = later pages.
    private func contentNeighbor(of viewController: UIViewController, offset: Int) -> UIViewController? {
        guard !pageViewControllers.isEmpty else { return nil }

        if viewController === trailingBlankPageViewController {
            return offset < 0 ? pageViewControllers.last : nil
        }
        if viewController === emptyPageViewController {
            return nil
        }

        guard let currentIdx = pageViewControllers.firstIndex(where: { $0 === viewController }) else {
            return nil
        }
        let targetIdx = currentIdx + offset
        if targetIdx >= 0, targetIdx < pageViewControllers.count {
            return pageViewControllers[targetIdx]
        }
        if offset > 0,
           isShowingDoublePage,
           pageViewControllers.count.isMultiple(of: 2) == false,
           currentIdx == pageViewControllers.count - 1 {
            return trailingBlankPageViewController
        }
        return nil
    }

    // MARK: - ReaderReaderDelegate

    func moveLeft() {
        guard !isLoadingChapter, !isTransitioning else { return }
        if isRTL {
            advance(by: pageStep)
        } else {
            retreat(by: pageStep)
        }
    }

    func moveRight() {
        guard !isLoadingChapter, !isTransitioning else { return }
        if isRTL {
            retreat(by: pageStep)
        } else {
            advance(by: pageStep)
        }
    }

    private func advance(by step: Int) {
        guard !pageViewControllers.isEmpty else { return }
        let target = currentPage + step
        if target <= pageViewControllers.count {
            move(toPage: target, animated: true)
        } else if let next = delegate?.getNextChapter() {
            delegate?.setChapter(next)
            setChapter(next, startPage: 1)
        }
    }

    private func retreat(by step: Int) {
        if currentPage > 1 {
            let target = max(1, currentPage - step)
            move(toPage: target, animated: true)
        } else if let prev = delegate?.getPreviousChapter() {
            delegate?.setChapter(prev)
            setChapter(prev, startPage: Int.max)
        }
    }

    func sliderMoved(value: CGFloat) {
        guard !isLoadingChapter, !pageViewControllers.isEmpty else { return }
        let count = pageViewControllers.count
        let page = count == 1 ? 1 : Int(round(value * CGFloat(count - 1))) + 1
        delegate?.displayPage(page)
    }

    func sliderStopped(value: CGFloat) {
        guard !isLoadingChapter, !pageViewControllers.isEmpty else { return }
        let count = pageViewControllers.count
        let page = count == 1 ? 1 : Int(round(value * CGFloat(count - 1))) + 1
        move(toPage: page, animated: false)
    }

    func setChapter(_ chapter: AidokuRunner.Chapter, startPage: Int) {
        loadChapterTask?.cancel()
        self.chapter = chapter
        isLoadingChapter = true
        isTransitioning = false
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
                target = alignedPage(pages.count, doublePage: isDoublePage)
            } else {
                target = alignedPage(max(1, min(startPage, pages.count)), doublePage: isDoublePage)
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
        // Content-ordered. Curl direction is flipped via semanticContentAttribute for RTL.
        contentNeighbor(of: viewController, offset: -1)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        contentNeighbor(of: viewController, offset: 1)
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
        for vc in pendingViewControllers {
            if let idx = pageIndex(of: vc), idx >= 0, idx < pages.count, idx < pageViewControllers.count {
                pageViewControllers[idx].setPage(
                    pages[idx],
                    sourceId: viewModel.source?.key ?? viewModel.manga.sourceKey
                )
            }
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
        guard completed, let vcs = pageViewController.viewControllers, !vcs.isEmpty else { return }
        let indices = vcs.compactMap { pageIndex(of: $0) }
        guard let minIdx = indices.min(), minIdx >= 0 else { return }
        currentPage = alignedPage(minIdx + 1)
        loadPagesAround(currentPage)
        reportCurrentPage()
    }
}