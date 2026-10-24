import SwiftUI
import UIKit

/// Everything the guide grid needs to draw one frame.
struct GuideSnapshot {
    var channels: [Channel]
    var listRevision: Int
    var epg: [String: [Program]]
    var epgState: [String: EPGLoad]
    var epgRevision: Int
    var isXtream: Bool
    var focusIndex: Int
    var focusStart: Date?
    var playingId: String?
    var favorites: Set<String>
    var now: Date
    var clock24: Bool
    var compact: Bool
    var rangeStart: Date
    var rangeEnd: Date
    var scrollToken: Int
    var jumpNowToken: Int
    var groupTitle: String
    var emptyText: String
}

struct GuideGrid: UIViewRepresentable {
    let snapshot: GuideSnapshot
    var onTapProgram: @MainActor (Int, Program?) -> Void
    var onTapChannel: @MainActor (Int) -> Void
    var onLongPressChannel: @MainActor (Int) -> Void
    var onVisibleChannels: @MainActor ([String]) -> Void
    var onTapCorner: @MainActor () -> Void

    func makeUIView(context: Context) -> GuideGridView { GuideGridView(frame: .zero) }

    func updateUIView(_ view: GuideGridView, context: Context) {
        view.onTapProgram = onTapProgram
        view.onTapChannel = onTapChannel
        view.onLongPressChannel = onLongPressChannel
        view.onVisibleChannels = onVisibleChannels
        view.onTapCorner = onTapCorner
        view.apply(snapshot)
    }
}

// MARK: - Grid view

/// TV guide: channels down the side, time across the top, both pinned while the programs scroll.
final class GuideGridView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    var onTapProgram: @MainActor (Int, Program?) -> Void = { _, _ in }
    var onTapChannel: @MainActor (Int) -> Void = { _ in }
    var onLongPressChannel: @MainActor (Int) -> Void = { _ in }
    var onVisibleChannels: @MainActor ([String]) -> Void = { _ in }
    var onTapCorner: @MainActor () -> Void = {}

    private(set) var snap: GuideSnapshot?
    let layout = EPGLayout()
    private var collection: UICollectionView!
    private let emptyLabel = UILabel()
    private weak var corner: CornerView?
    private var needsJumpNow = false
    private var needsEnsureVisible = false
    private var reportTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.panel
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Palette.line.cgColor
        clipsToBounds = true

        layout.grid = self
        collection = UICollectionView(frame: bounds, collectionViewLayout: layout)
        collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.showsHorizontalScrollIndicator = false
        collection.isDirectionalLockEnabled = true
        collection.contentInsetAdjustmentBehavior = .never
        collection.register(ProgramCell.self, forCellWithReuseIdentifier: "program")
        collection.register(ChannelHeaderView.self, forSupplementaryViewOfKind: EPGLayout.channelKind, withReuseIdentifier: "channel")
        collection.register(TimeHeaderView.self, forSupplementaryViewOfKind: EPGLayout.timeKind, withReuseIdentifier: "time")
        collection.register(CornerView.self, forSupplementaryViewOfKind: EPGLayout.cornerKind, withReuseIdentifier: "corner")
        collection.register(NowLineView.self, forSupplementaryViewOfKind: EPGLayout.nowKind, withReuseIdentifier: "now")
        addSubview(collection)

        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = Palette.fg2
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateMetrics()
        emptyLabel.frame = bounds.insetBy(dx: 24, dy: 24)
        guard bounds.width > 0, let s = snap, !s.channels.isEmpty else { return }
        if needsJumpNow {
            needsJumpNow = false
            collection.layoutIfNeeded()
            scrollToNow()
        }
        if needsEnsureVisible {
            needsEnsureVisible = false
            ensureVisible()
        }
    }

    private func updateMetrics() {
        guard bounds.width > 0 else { return }
        let wide = bounds.width >= 600
        let compact = snap?.compact ?? false
        let chanW: CGFloat = wide ? 220 : 112
        let ppm: CGFloat = wide ? 6 : 3.6
        let rowH: CGFloat = wide ? (compact ? 52 : 64) : (compact ? 48 : 58)
        let headH: CGFloat = wide ? 40 : 36
        guard layout.chanW != chanW || layout.ppm != ppm || layout.rowH != rowH || layout.headH != headH else { return }
        let leftTime = time(atX: collection.contentOffset.x)
        let topRow = collection.contentOffset.y / max(1, layout.rowH)
        layout.chanW = chanW
        layout.ppm = ppm
        layout.rowH = rowH
        layout.headH = headH
        layout.invalidateLayout()
        collection.layoutIfNeeded()
        collection.contentOffset = CGPoint(x: clampX(x(for: leftTime)), y: clampY(topRow * rowH))
    }

    // MARK: Updates from SwiftUI

    func apply(_ incoming: GuideSnapshot) {
        var s = incoming
        let old = snap
        var needsReload = true
        if let old, old.listRevision == s.listRevision, old.epgRevision == s.epgRevision,
           old.rangeStart == s.rangeStart, old.compact == s.compact {
            // Keep the data the collection view already knows about until a revision says otherwise.
            s.channels = old.channels
            s.epg = old.epg
            needsReload = false
        }
        snap = s
        emptyLabel.text = s.emptyText
        emptyLabel.isHidden = !s.channels.isEmpty
        updateMetrics()

        if needsReload {
            collection.reloadData()
            scheduleVisibleReport()
        } else if let old, changedVisibleState(old, s) {
            refreshVisible()
        }
        if old == nil || old?.jumpNowToken != s.jumpNowToken {
            needsJumpNow = true
            setNeedsLayout()
        }
        if let old, old.scrollToken != s.scrollToken {
            needsEnsureVisible = true
            setNeedsLayout()
        }
    }

    private func changedVisibleState(_ a: GuideSnapshot, _ b: GuideSnapshot) -> Bool {
        a.focusIndex != b.focusIndex || a.focusStart != b.focusStart || a.playingId != b.playingId ||
            a.favorites != b.favorites || a.now != b.now || a.clock24 != b.clock24 ||
            a.groupTitle != b.groupTitle || a.epgState.count != b.epgState.count
    }

    private func refreshVisible() {
        for ip in collection.indexPathsForVisibleItems {
            if let cell = collection.cellForItem(at: ip) as? ProgramCell { configure(cell, at: ip) }
        }
        for ip in collection.indexPathsForVisibleSupplementaryElements(ofKind: EPGLayout.channelKind) {
            if let v = collection.supplementaryView(forElementKind: EPGLayout.channelKind, at: ip) as? ChannelHeaderView {
                configure(v, section: ip.section)
            }
        }
        for ip in collection.indexPathsForVisibleSupplementaryElements(ofKind: EPGLayout.timeKind) {
            if let v = collection.supplementaryView(forElementKind: EPGLayout.timeKind, at: ip) as? TimeHeaderView {
                configureTime(v, item: ip.item)
            }
        }
        if let v = collection.supplementaryView(forElementKind: EPGLayout.nowKind, at: IndexPath(item: 0, section: 0)) as? NowLineView {
            v.label.text = Fmt.time(snap?.now ?? Date(), snap?.clock24 ?? false)
            v.setNeedsLayout()
        }
        updateCorner()
        layout.invalidateLayout()
    }

    // MARK: Geometry helpers

    func programs(_ section: Int) -> [Program] {
        guard let s = snap, s.channels.indices.contains(section) else { return [] }
        return s.epg[s.channels[section].id] ?? []
    }

    func time(atX x: CGFloat) -> Date {
        let start = snap?.rangeStart ?? Date()
        return start.addingTimeInterval(Double(max(0, x) / max(0.1, layout.ppm)) * 60)
    }

    func x(for t: Date) -> CGFloat {
        guard let start = snap?.rangeStart else { return 0 }
        return CGFloat(t.timeIntervalSince(start) / 60) * layout.ppm
    }

    private func clampX(_ v: CGFloat) -> CGFloat {
        max(0, min(v, layout.collectionViewContentSize.width - collection.bounds.width))
    }

    private func clampY(_ v: CGFloat) -> CGFloat {
        max(0, min(v, layout.collectionViewContentSize.height - collection.bounds.height))
    }

    private func scrollToNow() {
        guard let s = snap else { return }
        let half = Date(timeIntervalSince1970: floor(s.now.timeIntervalSince1970 / 1800) * 1800)
        var offset = collection.contentOffset
        offset.x = clampX(x(for: half) - 4)
        let rowTop = CGFloat(s.focusIndex) * layout.rowH
        let viewH = collection.bounds.height - layout.headH
        if rowTop < offset.y || rowTop + layout.rowH > offset.y + viewH {
            offset.y = clampY(rowTop - layout.rowH)
        }
        collection.setContentOffset(offset, animated: false)
        updateCorner()
    }

    private func ensureVisible() {
        guard let s = snap, s.channels.indices.contains(s.focusIndex) else { return }
        var offset = collection.contentOffset
        let rowTop = CGFloat(s.focusIndex) * layout.rowH
        let viewH = collection.bounds.height - layout.headH
        if rowTop < offset.y {
            offset.y = rowTop
        } else if rowTop + layout.rowH > offset.y + viewH {
            offset.y = rowTop + layout.rowH - viewH
        }
        if let start = s.focusStart, let p = programs(s.focusIndex).first(where: { $0.start == start }) {
            let l = x(for: max(p.start, s.rangeStart))
            let r = x(for: min(p.end, s.rangeEnd))
            let viewW = collection.bounds.width - layout.chanW
            if l >= offset.x + viewW - 40 {
                offset.x = l - 30 * layout.ppm
            } else if r <= offset.x + 40 {
                offset.x = r - viewW + 30 * layout.ppm
            }
        }
        collection.setContentOffset(CGPoint(x: clampX(offset.x), y: clampY(offset.y)), animated: true)
    }

    private func updateCorner() {
        guard let corner, let s = snap else { return }
        let t = time(atX: collection.contentOffset.x).addingTimeInterval(20 * 60)
        corner.configure(title: s.groupTitle, date: Fmt.day(t, now: s.now))
    }

    private func scheduleVisibleReport() {
        reportTask?.cancel()
        reportTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self?.reportVisible()
        }
    }

    private func reportVisible() {
        guard let s = snap, s.isXtream, !s.channels.isEmpty else { return }
        let b = collection.bounds
        let first = max(0, Int(floor(b.minY / layout.rowH)) - 2)
        let last = min(s.channels.count - 1, Int(ceil((b.maxY - layout.headH) / layout.rowH)) + 2)
        guard first <= last else { return }
        onVisibleChannels(s.channels[first...last].map { $0.id })
    }

    // MARK: Data source

    func numberOfSections(in collectionView: UICollectionView) -> Int { snap?.channels.count ?? 0 }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        max(1, programs(section).count)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "program", for: indexPath) as! ProgramCell
        configure(cell, at: indexPath)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        switch kind {
        case EPGLayout.channelKind:
            let v = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "channel", for: indexPath) as! ChannelHeaderView
            configure(v, section: indexPath.section)
            return v
        case EPGLayout.timeKind:
            let v = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "time", for: indexPath) as! TimeHeaderView
            configureTime(v, item: indexPath.item)
            return v
        case EPGLayout.cornerKind:
            let v = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "corner", for: indexPath) as! CornerView
            v.onTap = { [weak self] in self?.onTapCorner() }
            corner = v
            updateCorner()
            return v
        default:
            let v = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "now", for: indexPath) as! NowLineView
            v.label.text = Fmt.time(snap?.now ?? Date(), snap?.clock24 ?? false)
            return v
        }
    }

    private func configure(_ cell: ProgramCell, at ip: IndexPath) {
        guard let s = snap, s.channels.indices.contains(ip.section) else { return }
        let ch = s.channels[ip.section]
        let ps = programs(ip.section)
        let focusedRow = ip.section == s.focusIndex
        guard ps.indices.contains(ip.item) else {
            let st = s.epgState[ch.id]
            let loading = s.isXtream && st != .done && st != .failed
            cell.configurePlaceholder(loading ? "Loading guide…" : "No program information", focused: focusedRow && s.focusStart == nil)
            return
        }
        let p = ps[ip.item]
        let n = s.now
        let isNow = p.isNow(n)
        let isPast = p.end <= n
        let catchup = isPast && ch.archive && p.start >= n.addingTimeInterval(-Double(max(1, ch.archiveDays)) * 86400)
        var progress: CGFloat = 0
        if isNow {
            let total = p.end.timeIntervalSince(p.start)
            progress = total > 0 ? CGFloat(n.timeIntervalSince(p.start) / total) : 0
        }
        cell.configure(title: p.title,
                       time: "\(Fmt.time(p.start, s.clock24)) – \(Fmt.time(p.end, s.clock24))",
                       isNow: isNow, isPast: isPast, live: p.live && isNow, catchup: catchup,
                       focused: focusedRow && s.focusStart == p.start, progress: progress)
    }

    private func configure(_ v: ChannelHeaderView, section: Int) {
        guard let s = snap, s.channels.indices.contains(section) else { return }
        let ch = s.channels[section]
        v.configure(ch, focused: section == s.focusIndex, playing: ch.id == s.playingId, favorite: s.favorites.contains(ch.id))
        v.onTap = { [weak self] in self?.onTapChannel(section) }
        v.onLongPress = { [weak self] in self?.onLongPressChannel(section) }
    }

    private func configureTime(_ v: TimeHeaderView, item: Int) {
        guard let s = snap else { return }
        let t = s.rangeStart.addingTimeInterval(Double(item) * 1800)
        v.configure(t, clock24: s.clock24, now: s.now)
    }

    // MARK: Delegate

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        let ps = programs(indexPath.section)
        onTapProgram(indexPath.section, ps.indices.contains(indexPath.item) ? ps[indexPath.item] : nil)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCorner()
        scheduleVisibleReport()
    }
}

// MARK: - Layout

final class EPGAttributes: UICollectionViewLayoutAttributes {
    /// For program cells: how far to push the title right so it stays readable. For the now line: header height.
    var textOffset: CGFloat = 0

    override func copy(with zone: NSZone? = nil) -> Any {
        let c = super.copy(with: zone) as! EPGAttributes
        c.textOffset = textOffset
        return c
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? EPGAttributes, o.textOffset == textOffset else { return false }
        return super.isEqual(object)
    }
}

final class EPGLayout: UICollectionViewLayout {
    static let channelKind = "channel"
    static let timeKind = "time"
    static let cornerKind = "corner"
    static let nowKind = "now"

    weak var grid: GuideGridView?
    var chanW: CGFloat = 112
    var rowH: CGFloat = 58
    var headH: CGFloat = 36
    var ppm: CGFloat = 3.6  // points per minute

    override class var layoutAttributesClass: AnyClass { EPGAttributes.self }

    private var rowCount: Int { grid?.snap?.channels.count ?? 0 }

    private var timeWidth: CGFloat {
        guard let s = grid?.snap else { return 0 }
        return CGFloat(s.rangeEnd.timeIntervalSince(s.rangeStart) / 60) * ppm
    }

    private var pinned: CGPoint {
        let o = collectionView?.contentOffset ?? .zero
        return CGPoint(x: max(0, o.x), y: max(0, o.y))
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: chanW + timeWidth, height: headH + CGFloat(rowCount) * rowH)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let g = grid, let s = g.snap, rowCount > 0 else { return [] }
        var out: [UICollectionViewLayoutAttributes] = []
        let first = max(0, Int(floor((rect.minY - headH) / rowH)))
        let last = min(rowCount - 1, Int(floor((rect.maxY - headH) / rowH)))
        if first <= last {
            let t0 = g.time(atX: rect.minX - chanW)
            let t1 = g.time(atX: rect.maxX - chanW)
            for section in first...last {
                out.append(channelAttributes(section))
                let ps = g.programs(section)
                if ps.isEmpty {
                    out.append(itemAttributes(IndexPath(item: 0, section: section), nil))
                    continue
                }
                var k = ps.firstIndex(endingAfter: t0)
                while k < ps.count && ps[k].start < t1 {
                    out.append(itemAttributes(IndexPath(item: k, section: section), ps[k]))
                    k += 1
                }
            }
        }
        let tick = 30 * ppm
        let tickCount = Int(ceil(timeWidth / tick))
        let a = max(0, Int(floor((rect.minX - chanW) / tick)))
        let b = min(tickCount - 1, Int(floor((rect.maxX - chanW) / tick)))
        if a <= b {
            for k in a...b { out.append(timeAttributes(k)) }
        }
        out.append(cornerAttributes())
        out.append(nowAttributes(s.now))
        return out
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let g = grid else { return nil }
        let ps = g.programs(indexPath.section)
        return itemAttributes(indexPath, ps.indices.contains(indexPath.item) ? ps[indexPath.item] : nil)
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: String, at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        switch elementKind {
        case EPGLayout.channelKind: return channelAttributes(indexPath.section)
        case EPGLayout.timeKind: return timeAttributes(indexPath.item)
        case EPGLayout.cornerKind: return cornerAttributes()
        case EPGLayout.nowKind: return nowAttributes(grid?.snap?.now ?? Date())
        default: return nil
        }
    }

    private func itemAttributes(_ ip: IndexPath, _ p: Program?) -> EPGAttributes {
        let a = EPGAttributes(forCellWith: ip)
        let y = headH + CGFloat(ip.section) * rowH
        var x0 = chanW
        var x1 = chanW + timeWidth
        if let p, let g = grid {
            x0 = max(chanW, chanW + g.x(for: p.start))
            x1 = min(chanW + timeWidth, chanW + g.x(for: p.end))
        }
        a.frame = CGRect(x: x0 + 1, y: y + 2, width: max(0, x1 - x0 - 2), height: max(0, rowH - 4))
        let visibleLeft = pinned.x + chanW
        a.textOffset = max(0, min(visibleLeft - a.frame.minX, a.frame.width - 72))
        a.zIndex = 0
        return a
    }

    private func channelAttributes(_ section: Int) -> EPGAttributes {
        let a = EPGAttributes(forSupplementaryViewOfKind: EPGLayout.channelKind, with: IndexPath(item: 0, section: section))
        a.frame = CGRect(x: pinned.x, y: headH + CGFloat(section) * rowH, width: chanW, height: rowH)
        a.zIndex = 10
        return a
    }

    private func timeAttributes(_ k: Int) -> EPGAttributes {
        let a = EPGAttributes(forSupplementaryViewOfKind: EPGLayout.timeKind, with: IndexPath(item: k, section: 0))
        a.frame = CGRect(x: chanW + CGFloat(k) * 30 * ppm, y: pinned.y, width: 30 * ppm, height: headH)
        a.zIndex = 20
        return a
    }

    private func cornerAttributes() -> EPGAttributes {
        let a = EPGAttributes(forSupplementaryViewOfKind: EPGLayout.cornerKind, with: IndexPath(item: 0, section: 0))
        a.frame = CGRect(x: pinned.x, y: pinned.y, width: chanW, height: headH)
        a.zIndex = 30
        return a
    }

    private func nowAttributes(_ now: Date) -> EPGAttributes {
        let a = EPGAttributes(forSupplementaryViewOfKind: EPGLayout.nowKind, with: IndexPath(item: 0, section: 0))
        let nx = chanW + (grid?.x(for: now) ?? 0)
        let height = max(headH, collectionView?.bounds.height ?? headH)
        a.frame = CGRect(x: nx - 32, y: pinned.y, width: 64, height: height)
        a.zIndex = 25
        a.textOffset = headH
        a.isHidden = nx < pinned.x + chanW + 2 || nx > chanW + timeWidth
        return a
    }
}

// MARK: - Cells

final class ProgramCell: UICollectionViewCell {
    private let box = UIView()
    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let bar = UIView()
    private let liveTag = UILabel()
    private let replayIcon = UIImageView(image: UIImage(systemName: "gobackward"))
    private var textOffset: CGFloat = 0
    private var progress: CGFloat = 0
    private var isPlaceholder = false
    private var showLive = false
    private var showReplay = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        box.layer.cornerRadius = 7
        box.layer.cornerCurve = .continuous
        box.clipsToBounds = true
        contentView.addSubview(box)
        titleLabel.font = TFont.cond(15, .medium)
        timeLabel.font = TFont.digits(11.5, .regular)
        liveTag.text = "LIVE"
        liveTag.font = TFont.cond(10, .bold)
        liveTag.textColor = .white
        liveTag.backgroundColor = Palette.live
        liveTag.textAlignment = .center
        liveTag.layer.cornerRadius = 3
        liveTag.clipsToBounds = true
        replayIcon.contentMode = .scaleAspectFit
        replayIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        for v in [titleLabel, timeLabel, liveTag, replayIcon, bar] as [UIView] { box.addSubview(v) }
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let a = layoutAttributes as? EPGAttributes, a.textOffset != textOffset {
            textOffset = a.textOffset
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        box.frame = contentView.bounds
        let w = bounds.width, h = bounds.height
        let tiny = w < 34
        titleLabel.isHidden = tiny
        timeLabel.isHidden = tiny || isPlaceholder
        liveTag.isHidden = tiny || !showLive
        replayIcon.isHidden = tiny || !showReplay
        let left = 10 + textOffset
        var x = left
        let titleH: CGFloat = 19, timeH: CGFloat = 14
        let block = isPlaceholder ? titleH : titleH + 3 + timeH
        let top = (h - block) / 2
        if !liveTag.isHidden {
            liveTag.frame = CGRect(x: x, y: top + 2.5, width: 30, height: 14)
            x += 35
        }
        if !replayIcon.isHidden {
            replayIcon.frame = CGRect(x: x, y: top + 3, width: 13, height: 13)
            x += 18
        }
        titleLabel.frame = CGRect(x: x, y: top, width: max(0, w - x - 8), height: titleH)
        timeLabel.frame = CGRect(x: left, y: top + titleH + 3, width: max(0, w - left - 8), height: timeH)
        bar.frame = CGRect(x: 0, y: h - 3, width: w * progress, height: 3)
    }

    func configure(title: String, time: String, isNow: Bool, isPast: Bool, live: Bool, catchup: Bool, focused: Bool, progress p: CGFloat) {
        isPlaceholder = false
        titleLabel.text = title
        timeLabel.text = time
        showLive = live
        showReplay = catchup
        progress = isNow ? max(0, min(1, p)) : 0
        box.layer.borderWidth = 0
        if focused {
            box.backgroundColor = Palette.accent
            titleLabel.textColor = Palette.accentInk
            timeLabel.textColor = Palette.accentInk.withAlphaComponent(0.75)
            replayIcon.tintColor = Palette.accentInk
            bar.backgroundColor = Palette.accentInk.withAlphaComponent(0.35)
        } else {
            box.backgroundColor = isNow ? Palette.cellNow : Palette.cell
            titleLabel.textColor = isPast ? Palette.fg2 : Palette.fg
            timeLabel.textColor = Palette.fg3
            replayIcon.tintColor = Palette.fg2
            bar.backgroundColor = Palette.accent
        }
        accessibilityLabel = "\(title), \(time)\(live ? ", live" : "")"
        setNeedsLayout()
    }

    func configurePlaceholder(_ text: String, focused: Bool) {
        isPlaceholder = true
        showLive = false
        showReplay = false
        progress = 0
        titleLabel.text = text
        timeLabel.text = nil
        box.backgroundColor = focused ? Palette.accent.withAlphaComponent(0.16) : .clear
        box.layer.borderWidth = 1
        box.layer.borderColor = (focused ? Palette.accent : Palette.line).cgColor
        titleLabel.textColor = focused ? Palette.fg : Palette.fg3
        accessibilityLabel = text
        setNeedsLayout()
    }
}

final class LogoView: UIView {
    private let initialsLabel = UILabel()
    private let imageView = UIImageView()
    private var url: URL?
    private var hueColor = Palette.cell

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        clipsToBounds = true
        initialsLabel.font = TFont.cond(14, .bold)
        initialsLabel.textColor = .white
        initialsLabel.textAlignment = .center
        imageView.contentMode = .scaleAspectFit
        addSubview(initialsLabel)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        initialsLabel.frame = bounds
        imageView.frame = bounds.insetBy(dx: 3, dy: 3)
    }

    func set(_ ch: Channel) {
        hueColor = Palette.logo(ch.hue)
        backgroundColor = hueColor
        initialsLabel.text = ch.initials
        initialsLabel.isHidden = false
        imageView.image = nil
        url = ch.logo
        guard let u = ch.logo else { return }
        ImageCache.shared.load(u) { [weak self] image in
            guard let self, self.url == u, let image else { return }
            self.imageView.image = image
            self.initialsLabel.isHidden = true
            self.backgroundColor = Palette.logoBack
        }
    }
}

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    private var failed = Set<URL>()
    private var waiting: [URL: [(UIImage?) -> Void]] = [:]

    func load(_ url: URL, _ done: @escaping (UIImage?) -> Void) {
        if let image = cache.object(forKey: url as NSURL) { done(image); return }
        if failed.contains(url) { done(nil); return }
        if waiting[url] != nil { waiting[url]?.append(done); return }
        waiting[url] = [done]
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                let shared = ImageCache.shared
                if let image { shared.cache.setObject(image, forKey: url as NSURL) } else { shared.failed.insert(url) }
                let callbacks = shared.waiting.removeValue(forKey: url) ?? []
                for cb in callbacks { cb(image) }
            }
        }.resume()
    }
}

final class ChannelHeaderView: UICollectionReusableView {
    private let numberLabel = UILabel()
    private let nameLabel = UILabel()
    private let logo = LogoView()
    private let badge = UIImageView()
    private let divider = UIView()
    private let bottomLine = UIView()
    var onTap: (@MainActor () -> Void)?
    var onLongPress: (@MainActor () -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.panel
        numberLabel.font = TFont.digits(13, .semibold)
        nameLabel.font = TFont.cond(15, .medium)
        nameLabel.textColor = Palette.fg
        nameLabel.numberOfLines = 2
        badge.tintColor = Palette.accent
        badge.contentMode = .scaleAspectFit
        divider.backgroundColor = Palette.line
        bottomLine.backgroundColor = Palette.lineSoft
        for v in [numberLabel, logo, nameLabel, badge, divider, bottomLine] as [UIView] { addSubview(v) }
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.require(toFail: long)
        addGestureRecognizer(long)
        addGestureRecognizer(tap)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func tapped() { onTap?() }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onLongPress?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        divider.frame = CGRect(x: w - 1, y: 0, width: 1, height: h)
        bottomLine.frame = CGRect(x: 0, y: h - 1, width: w, height: 1)
        badge.frame = CGRect(x: w - 22, y: 8, width: 14, height: 14)
        if w >= 180 {
            logo.isHidden = false
            numberLabel.textAlignment = .right
            numberLabel.frame = CGRect(x: 6, y: 0, width: 38, height: h)
            logo.frame = CGRect(x: 52, y: (h - 40) / 2, width: 40, height: 40)
            nameLabel.frame = CGRect(x: 102, y: 0, width: max(0, w - 102 - 26), height: h)
        } else {
            logo.isHidden = true
            numberLabel.textAlignment = .left
            numberLabel.frame = CGRect(x: 8, y: 6, width: max(0, w - 34), height: 15)
            nameLabel.frame = CGRect(x: 8, y: 21, width: max(0, w - 16), height: max(0, h - 25))
        }
    }

    func configure(_ ch: Channel, focused: Bool, playing: Bool, favorite: Bool) {
        numberLabel.text = String(ch.num)
        numberLabel.textColor = focused ? Palette.accent : Palette.fg3
        nameLabel.text = ch.name
        backgroundColor = focused ? Palette.cellNow : Palette.panel
        logo.set(ch)
        if playing {
            badge.image = UIImage(systemName: "speaker.wave.2.fill")
        } else if favorite {
            badge.image = UIImage(systemName: "star.fill")
        } else {
            badge.image = nil
        }
        accessibilityLabel = "Channel \(ch.num), \(ch.name)\(playing ? ", playing" : "")\(favorite ? ", favorite" : "")"
        accessibilityHint = "Touch and hold to add or remove from favorites"
    }
}

final class TimeHeaderView: UICollectionReusableView {
    private let label = UILabel()
    private let tick = UIView()
    private let bottomLine = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.panel
        label.font = TFont.digits(13, .medium)
        tick.backgroundColor = Palette.line
        bottomLine.backgroundColor = Palette.line
        addSubview(tick)
        addSubview(label)
        addSubview(bottomLine)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        tick.frame = CGRect(x: 0, y: 0, width: 1, height: h)
        label.frame = CGRect(x: 8, y: 5, width: max(0, w - 10), height: 16)
        bottomLine.frame = CGRect(x: 0, y: h - 1, width: w, height: 1)
    }

    func configure(_ t: Date, clock24: Bool, now: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: t)
        let midnight = c.hour == 0 && c.minute == 0
        label.text = midnight ? "\(Fmt.day(t, now: now).uppercased()) · \(Fmt.time(t, clock24))" : Fmt.time(t, clock24)
        label.textColor = midnight ? Palette.accent : Palette.fg2
    }
}

final class CornerView: UICollectionReusableView {
    private let titleLabel = UILabel()
    private let dateLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))
    private let divider = UIView()
    private let bottomLine = UIView()
    var onTap: (@MainActor () -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.panel
        titleLabel.font = TFont.cond(14, .semibold)
        titleLabel.textColor = Palette.fg
        dateLabel.font = TFont.cond(10.5, .semibold)
        dateLabel.textColor = Palette.fg3
        chevron.tintColor = Palette.fg3
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        divider.backgroundColor = Palette.line
        bottomLine.backgroundColor = Palette.line
        for v in [titleLabel, dateLabel, chevron, divider, bottomLine] as [UIView] { addSubview(v) }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Choose a channel group"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func tapped() { onTap?() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        titleLabel.frame = CGRect(x: 10, y: h / 2 - 15, width: max(0, w - 32), height: 17)
        chevron.frame = CGRect(x: w - 20, y: h / 2 - 12, width: 12, height: 12)
        dateLabel.frame = CGRect(x: 10, y: h / 2 + 3, width: max(0, w - 16), height: 12)
        divider.frame = CGRect(x: w - 1, y: 0, width: 1, height: h)
        bottomLine.frame = CGRect(x: 0, y: h - 1, width: w, height: 1)
    }

    func configure(title: String, date: String) {
        titleLabel.text = title
        dateLabel.text = date.uppercased()
        accessibilityLabel = "\(title). \(date)"
    }
}

final class NowLineView: UICollectionReusableView {
    let label = UILabel()
    private let line = UIView()
    private let pill = UIView()
    private var headH: CGFloat = 36

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        pill.backgroundColor = Palette.accent
        pill.layer.cornerRadius = 4
        pill.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        label.font = TFont.digits(10.5, .bold)
        label.textColor = Palette.accentInk
        label.textAlignment = .center
        line.backgroundColor = Palette.accent
        line.layer.shadowColor = Palette.accent.cgColor
        line.layer.shadowOpacity = 0.5
        line.layer.shadowRadius = 5
        line.layer.shadowOffset = .zero
        addSubview(line)
        addSubview(pill)
        pill.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let a = layoutAttributes as? EPGAttributes, a.textOffset != headH {
            headH = a.textOffset
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        let pillW = min(w, label.intrinsicContentSize.width + 10)
        pill.frame = CGRect(x: (w - pillW) / 2, y: headH - 15, width: pillW, height: 15)
        label.frame = pill.bounds
        line.frame = CGRect(x: w / 2 - 1, y: headH, width: 2, height: max(0, h - headH))
    }
}
