import UIKit

@objc(WMFPageHistoryViewControllerDelegate)
protocol PageHistoryViewControllerDelegate: AnyObject {
    func pageHistoryViewControllerDidDisappear(_ pageHistoryViewController: PageHistoryViewController)
}

@objc(WMFPageHistoryViewController)
class PageHistoryViewController: ColumnarCollectionViewController {
    private let pageTitle: String
    private let pageURL: URL

    private let pageHistoryFetcher = PageHistoryFetcher()
    private var pageHistoryFetcherParams: PageHistoryRequestParameters

    private var batchComplete = false
    private var isLoadingData = false

    private var cellLayoutEstimate: ColumnarCollectionViewLayoutHeightEstimate?

    var shouldLoadNewData: Bool {
        if batchComplete || isLoadingData {
            return false
        }
        let maxY = collectionView.contentOffset.y + collectionView.frame.size.height + 200.0;
        if (maxY >= collectionView.contentSize.height) {
            return true
        }
        return false;
    }

    @objc public weak var delegate: PageHistoryViewControllerDelegate?

    private lazy var statsViewController = PageHistoryStatsViewController(pageTitle: pageTitle, locale: NSLocale.wmf_locale(for: pageURL.wmf_language))

    @objc init(pageTitle: String, pageURL: URL) {
        self.pageTitle = pageTitle
        self.pageURL = pageURL
        self.pageHistoryFetcherParams = PageHistoryRequestParameters(title: pageTitle)
        super.init()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var pageHistorySections: [PageHistorySection] = []

    override var headerStyle: ColumnarCollectionViewController.HeaderStyle {
        return .sections
    }

    private lazy var compareButton = UIBarButtonItem(title: WMFLocalizedString("page-history-compare-title", value: "Compare", comment: "Title for action button that allows users to contrast different items"), style: .plain, target: self, action: #selector(compare(_:)))
    private lazy var cancelComparisonButton = UIBarButtonItem(title: CommonStrings.cancelActionTitle, style: .done, target: self, action: #selector(cancelComparison(_:)))

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.backBarButtonItem = UIBarButtonItem(title: "Article", style: .plain, target: nil, action: nil)
        navigationItem.rightBarButtonItem = compareButton
        title = CommonStrings.historyTabTitle

        addChild(statsViewController)
        navigationBar.addUnderNavigationBarView(statsViewController.view)
        navigationBar.shadowColorKeyPath = \Theme.colors.border
        statsViewController.didMove(toParent: self)

        collectionView.register(PageHistoryCollectionViewCell.self, forCellWithReuseIdentifier: PageHistoryCollectionViewCell.identifier)
        collectionView.dataSource = self
        view.wmf_addSubviewWithConstraintsToEdges(collectionView)

        apply(theme: theme)

        // TODO: Move networking

        pageHistoryFetcher.fetchPageCreationDate(for: pageTitle, pageURL: pageURL) { result in
            switch result {
            case .failure(let error):
                // TODO: Handle error
                print(error)
            case .success(let firstEditDate):
                self.pageHistoryFetcher.fetchEditCounts(.edits, for: self.pageTitle, pageURL: self.pageURL) { result in
                    switch result {
                    case .failure(let error):
                        // TODO: Handle error
                        print(error)
                    case .success(let editCounts):
                        if case let totalEditCount?? = editCounts[.edits] {
                            DispatchQueue.main.async {
                                self.statsViewController.set(totalEditCount: totalEditCount, firstEditDate: firstEditDate)
                            }
                        }
                    }
                }
            }
        }

        pageHistoryFetcher.fetchEditCounts(.edits, .anonEdits, .botEdits, .revertedEdits, for: pageTitle, pageURL: pageURL) { result in
            switch result {
            case .failure(let error):
                // TODO: Handle error
                print(error)
            case .success(let editCountsGroupedByType):
                DispatchQueue.main.async {
                    self.statsViewController.editCountsGroupedByType = editCountsGroupedByType
                }
            }
        }

        pageHistoryFetcher.fetchEditMetrics(for: pageTitle, pageURL: pageURL) { result in
            switch result {
            case .failure(let error):
                // TODO: Handle error
                print(error)
                self.statsViewController.timeseriesOfEditsCounts = []
            case .success(let timeseriesOfEditCounts):
                DispatchQueue.main.async {
                    self.statsViewController.timeseriesOfEditsCounts = timeseriesOfEditCounts
                }
            }
        }

        getPageHistory()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelComparison(nil)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        delegate?.pageHistoryViewControllerDidDisappear(self)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        cellLayoutEstimate = nil
    }

    private func getPageHistory() {
        isLoadingData = true

        pageHistoryFetcher.fetchRevisionInfo(pageURL, requestParams: pageHistoryFetcherParams, failure: { error in
            print(error)
            self.isLoadingData = false
        }) { results in
            self.pageHistorySections.append(contentsOf: results.items())
            self.pageHistoryFetcherParams = results.getPageHistoryRequestParameters(self.pageURL)
            self.batchComplete = results.batchComplete()
            self.isLoadingData = false
            DispatchQueue.main.async {
                self.collectionView.reloadData()
            }
        }
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        super.scrollViewDidScroll(scrollView)
        guard shouldLoadNewData else {
            return
        }
        getPageHistory()
    }

    private enum State {
        case idle
        case editing
    }
    private var state: State = .idle {
        didSet {
            switch state {
            case .idle:
                openSelectionIndex = 0
                navigationItem.rightBarButtonItem = compareButton
                collectionView.indexPathsForSelectedItems?.forEach { collectionView.deselectItem(at: $0, animated: true) }
                forEachVisibleCell { (cell: PageHistoryCollectionViewCell) in
                    cell.selectionThemeModel = nil
                    cell.enableEditing(true) // confusing, have a reset method
                    cell.setEditing(false)
                }
                resetComparisonSelectionButtons()
                navigationController?.setToolbarHidden(true, animated: true)
            case .editing:
                navigationItem.rightBarButtonItem = cancelComparisonButton
                collectionView.allowsMultipleSelection = true
                forEachVisibleCell { $0.setEditing(true) }
                compareToolbarButton.isEnabled = false
                NSLayoutConstraint.activate([
                    firstComparisonSelectionButton.widthAnchor.constraint(equalToConstant: 90),
                    secondComparisonSelectionButton.widthAnchor.constraint(equalToConstant: 90)
                ])
                setToolbarItems([UIBarButtonItem(customView: firstComparisonSelectionButton), UIBarButtonItem.wmf_barButtonItem(ofFixedWidth: 10), UIBarButtonItem(customView: secondComparisonSelectionButton), UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil), UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),  compareToolbarButton], animated: true)
                navigationController?.setToolbarHidden(false, animated: true)
            }
            collectionView.collectionViewLayout.invalidateLayout()
            navigationItem.rightBarButtonItem?.tintColor = theme.colors.link
        }
    }

    private lazy var compareToolbarButton = UIBarButtonItem(title: "Compare", style: .plain, target: self, action: #selector(showDiff(_:)))
    private lazy var firstComparisonSelectionButton = makeComparisonSelectionButton()
    private lazy var secondComparisonSelectionButton = makeComparisonSelectionButton()

    private func makeComparisonSelectionButton() -> AlignedImageButton {
        let button = AlignedImageButton(frame: .zero)
        button.widthAnchor.constraint(equalToConstant: 90).isActive = true
        button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        button.cornerRadius = 8
        button.clipsToBounds = true
        button.backgroundColor = UIColor.white
        button.imageView?.tintColor = theme.colors.link
        button.setTitleColor(theme.colors.link, for: .normal)
        button.titleLabel?.font = UIFont.wmf_font(.semiboldSubheadline, compatibleWithTraitCollection: traitCollection)
        button.horizontalSpacing = 10
        button.contentHorizontalAlignment = .leading
        button.leftPadding = 10
        button.rightPadding = 10
        return button
    }

    @objc private func compare(_ sender: UIBarButtonItem) {
        state = .editing
    }

    @objc private func cancelComparison(_ sender: UIBarButtonItem?) {
        state = .idle
    }
    }

    override func apply(theme: Theme) {
        super.apply(theme: theme)
        guard viewIfLoaded != nil else {
            self.theme = theme
            return
        }
        view.backgroundColor = theme.colors.paperBackground
        collectionView.backgroundColor = view.backgroundColor
        navigationItem.rightBarButtonItem?.tintColor = theme.colors.link
        navigationItem.leftBarButtonItem?.tintColor = theme.colors.primaryText
        statsViewController.apply(theme: theme)
    }

    // MARK: UICollectionViewDataSource

    override func numberOfSections(in collectionView: UICollectionView) -> Int {
        return pageHistorySections.count
    }

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return pageHistorySections[section].items.count
    }

    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PageHistoryCollectionViewCell.identifier, for: indexPath) as? PageHistoryCollectionViewCell else {
            return UICollectionViewCell()
        }
        let item = pageHistorySections[indexPath.section].items[indexPath.item]
        configure(cell: cell, for: item, at: indexPath)
        return cell
    }

    override func configure(header: CollectionViewHeader, forSectionAt sectionIndex: Int, layoutOnly: Bool) {
        let section = pageHistorySections[sectionIndex]
        let sectionTitle: String?

        if sectionIndex == 0, let date = section.items.first?.revisionDate {
            sectionTitle = (date as NSDate).wmf_localizedRelativeDateFromMidnightUTCDate()
        } else {
            sectionTitle = section.sectionTitle
        }
        header.style = .pageHistory
        header.title = sectionTitle
        header.titleTextColorKeyPath = \Theme.colors.secondaryText
        header.layoutMargins = .zero
        header.apply(theme: theme)
    }

    // MARK: Layout

    private func configure(cell: PageHistoryCollectionViewCell, for item: WMFPageHistoryRevision, at indexPath: IndexPath) {
        if let date = item.revisionDate {
            if (date as NSDate).wmf_isTodayUTC() {
                let diff = Calendar.current.dateComponents([.second, .minute, .hour], from: date, to: Date())
                if let hours = diff.hour {
                    // TODO: Localize
                    cell.time = "\(hours)h ago"
                } else if let minutes = diff.minute {
                    cell.time = "\(minutes)m ago"
                } else if let seconds = diff.second {
                    cell.time = "\(seconds)s ago"
                }
            } else if let dateString = DateFormatter.wmf_24hshortTime()?.string(from: date)  {
                cell.time = "\(dateString) UTC"
            }
        }
        // TODO: Use logged-in icon when available
        cell.authorImage = item.isAnon ? UIImage(named: "anon") : UIImage(named: "user-edit")
        cell.author = item.user
        cell.sizeDiff = item.revisionSize
        cell.comment = item.parsedComment?.removingHTML
        cell.apply(theme: theme)
    }

    override func collectionView(_ collectionView: UICollectionView, estimatedHeightForItemAt indexPath: IndexPath, forColumnWidth columnWidth: CGFloat) -> ColumnarCollectionViewLayoutHeightEstimate {
        // The layout estimate can be re-used in this case becuause both labels are one line, meaning the cell
        // size only varies with font size. The layout estimate is nil'd when the font size changes on trait collection change
        if let estimate = cellLayoutEstimate {
            return estimate
        }
        var estimate = ColumnarCollectionViewLayoutHeightEstimate(precalculated: false, height: 70)
        guard let placeholderCell = layoutManager.placeholder(forCellWithReuseIdentifier: PageHistoryCollectionViewCell.identifier) as? PageHistoryCollectionViewCell else {
            return estimate
        }
        let item = pageHistorySections[indexPath.section].items[indexPath.item]
        configure(cell: placeholderCell, for: item, at: indexPath)
        estimate.height = placeholderCell.sizeThatFits(CGSize(width: columnWidth, height: UIView.noIntrinsicMetric), apply: false).height
        estimate.precalculated = true
        cellLayoutEstimate = estimate
        return estimate
    }

    override func metrics(with boundsSize: CGSize, readableWidth: CGFloat, layoutMargins: UIEdgeInsets) -> ColumnarCollectionViewLayoutMetrics {
        return ColumnarCollectionViewLayoutMetrics.tableViewMetrics(with: boundsSize, readableWidth: readableWidth, layoutMargins: layoutMargins, interSectionSpacing: 0, interItemSpacing: 20)
    }
}
