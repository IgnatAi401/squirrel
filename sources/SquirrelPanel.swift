//
//  SquirrelPanel.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import AppKit
import os

final class SquirrelPanel: NSPanel {
  private let view: SquirrelView
  private let back: NSView
  var inputController: SquirrelInputController?

  var position: NSRect
  private var screenRect: NSRect = .zero
  private var maxHeight: CGFloat = 0

  private var statusMessage: String = ""
  private var statusTimer: Timer?

  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var candidates: [String] = .init()
  private var comments: [String] = .init()
  private var labels: [String] = .init()
  private var index: Int = 0
  private var cursorIndex: Int = 0
  private var scrollDirection: CGVector = .zero
  private var scrollTime: Date = .distantPast
  private var page: Int = 0
  private var lastPage: Bool = true
  private var pagingUp: Bool?
  // Expanded grid: candidates are laid out `gridColumns` per row (one Rime page per row); 0 = single bar.
  private var gridColumns: Int = 0
  // Row holding Rime's current page; only its labels are shown, since select keys act on the current page.
  private var gridRow: Int = 0
  // Lets a grid row be wider than the usual wrapping width.
  private var minTextWidth: CGFloat = 0
  // Size animation of the capsule panel (grid expanding / collapsing, bar width changing).
  fileprivate struct Reveal {
    var from: NSSize
    var to: NSSize
    var fromRadius: CGFloat
    var toRadius: CGFloat
    var start: CFTimeInterval
    var duration: CFTimeInterval
    var finalFrame: NSRect
    var naturalSize: NSSize
  }
  private var reveal: Reveal?
  private static let logger = Logger(subsystem: "im.rime.inputmethod.Squirrel", category: "panel")
  private var revealTimer: Timer?

  init(position: NSRect) {
    self.position = position
    self.view = SquirrelView(frame: position)
    self.back = Self.makeBackgroundView()
    super.init(contentRect: position, styleMask: .nonactivatingPanel, backing: .buffered, defer: true)
    self.level = .init(Int(CGShieldingWindowLevel()))
    self.hasShadow = true
    self.isOpaque = false
    self.backgroundColor = .clear
    back.wantsLayer = true
    back.layer?.mask = view.shape
    let contentView = NSView()
    contentView.addSubview(back)
    contentView.addSubview(view)
    contentView.addSubview(view.textView)
    view.textView.wantsLayer = true
    self.contentView = contentView
  }

  var linear: Bool {
    view.currentTheme.linear
  }
  var vertical: Bool {
    view.currentTheme.vertical
  }
  var inlinePreedit: Bool {
    view.currentTheme.inlinePreedit
  }
  var inlineCandidate: Bool {
    view.currentTheme.inlineCandidate
  }
  var expandRows: Int {
    view.currentTheme.expandRows
  }

  // swiftlint:disable:next cyclomatic_complexity
  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown:
      let (index, _, pagingUp) =  view.click(at: mousePosition())
      if let pagingUp {
        self.pagingUp = pagingUp
      } else {
        self.pagingUp = nil
      }
      if let index, index >= 0 && index < candidates.count {
        self.index = index
      }
    case .leftMouseUp:
      let (index, preeditIndex, pagingUp) = view.click(at: mousePosition())

      if let pagingUp, pagingUp == self.pagingUp {
        _ = inputController?.page(up: pagingUp)
      } else {
        self.pagingUp = nil
      }
      if let preeditIndex, preeditIndex >= 0 && preeditIndex < preedit.utf16.count {
        if preeditIndex < caretPos {
          _ = inputController?.moveCaret(forward: true)
        } else if preeditIndex > caretPos {
          _ = inputController?.moveCaret(forward: false)
        }
      }
      if let index, index == self.index && index >= 0 && index < candidates.count {
        _ = inputController?.selectCandidate(index)
      }
    case .mouseEntered:
      acceptsMouseMovedEvents = true
    case .mouseExited:
      acceptsMouseMovedEvents = false
      if cursorIndex != index {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, highlighted: index, page: page, lastPage: lastPage, update: false)
      }
      pagingUp = nil
    case .mouseMoved:
      let (index, _, _) = view.click(at: mousePosition())
      if let index = index, cursorIndex != index && index >= 0 && index < candidates.count {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, highlighted: index, page: page, lastPage: lastPage, update: false)
      }
    case .scrollWheel:
      if event.phase == .began {
        scrollDirection = .zero
      } else if event.phase == .ended || (event.phase == .init(rawValue: 0) && event.momentumPhase != .init(rawValue: 0)) {
        if abs(scrollDirection.dx) > abs(scrollDirection.dy) && abs(scrollDirection.dx) > 10 {
          _ = inputController?.page(up: (scrollDirection.dx < 0) == vertical)
        } else if abs(scrollDirection.dx) < abs(scrollDirection.dy) && abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
        }
        scrollDirection = .zero
      } else if event.phase == .init(rawValue: 0) && event.momentumPhase == .init(rawValue: 0) {
        if scrollTime.timeIntervalSinceNow < -1 {
          scrollDirection = .zero
        }
        scrollTime = .now
        if (scrollDirection.dy >= 0 && event.scrollingDeltaY > 0) || (scrollDirection.dy <= 0 && event.scrollingDeltaY < 0) {
          scrollDirection.dy += event.scrollingDeltaY
        } else {
          scrollDirection = .zero
        }
        if abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
          scrollDirection = .zero
        }
      } else {
        scrollDirection.dx += event.scrollingDeltaX
        scrollDirection.dy += event.scrollingDeltaY
      }
    default:
      break
    }
    super.sendEvent(event)
  }

  func hide() {
    stopReveal()
    statusTimer?.invalidate()
    statusTimer = nil
    orderOut(nil)
    maxHeight = 0
  }

  // swiftlint:disable:next cyclomatic_complexity function_parameter_count
  func update(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], highlighted index: Int, page: Int, lastPage: Bool, update: Bool,
              gridColumns: Int = 0, gridRow: Int = 0) {
    if update {
      self.gridColumns = gridColumns
      self.gridRow = gridRow
      self.preedit = preedit
      self.selRange = selRange
      self.caretPos = caretPos
      self.candidates = candidates
      self.comments = comments
      self.labels = labels
      self.index = index
      self.page = page
      self.lastPage = lastPage
    }
    cursorIndex = index

    if !candidates.isEmpty || !preedit.isEmpty {
      statusMessage = ""
      statusTimer?.invalidate()
      statusTimer = nil
    } else {
      if !statusMessage.isEmpty {
        show(status: statusMessage)
        statusMessage = ""
      } else if statusTimer == nil {
        hide()
      }
      return
    }

    let theme = view.currentTheme
    currentScreen()

    let text = NSMutableAttributedString()
    let preeditRange: NSRange
    let highlightedPreeditRange: NSRange

    if !preedit.isEmpty {
      preeditRange = NSRange(location: 0, length: preedit.utf16.count)
      highlightedPreeditRange = selRange

      let line = NSMutableAttributedString(string: preedit)
      line.addAttributes(theme.preeditAttrs, range: preeditRange)
      line.addAttributes(theme.preeditHighlightedAttrs, range: selRange)
      text.append(line)

      text.addAttribute(.paragraphStyle, value: theme.preeditParagraphStyle, range: NSRange(location: 0, length: text.length))
      if !candidates.isEmpty {
        text.append(NSAttributedString(string: "\n", attributes: theme.preeditAttrs))
      }
    } else {
      preeditRange = .empty
      highlightedPreeditRange = .empty
    }

    let columns = theme.isCapsule ? self.gridColumns : 0
    let isGrid = columns > 0
    var columnWidths = [CGFloat](repeating: 0, count: max(columns, 0))
    var candidateRanges = [NSRange]()
    for i in 0..<candidates.count {
      let attrs = i == index ? theme.highlightedAttrs : theme.attrs
      var labelAttrs = i == index ? theme.labelHighlightedAttrs : theme.labelAttrs
      // Position within the Rime page, which is what labels and comment marks refer to.
      let pageIndex = isGrid ? (i / columns == gridRow ? i % columns : -1) : i
      if isGrid && pageIndex < 0 {
        // Keep the label's width so columns stay aligned, but hide it: select keys only reach the current row.
        labelAttrs[.foregroundColor] = NSColor.clear
      }
      var commentAttrs = i == index ? theme.commentHighlightedAttrs : theme.commentAttrs

      let labelIndex = isGrid ? i % columns : i
      let label = if theme.candidateFormat.contains(/\[label\]/) {
        if labels.count > 1 && labelIndex < labels.count {
          labels[labelIndex]
        } else if labels.count == 1 && labelIndex < labels.first!.count {
          String(labels.first![labels.first!.index(labels.first!.startIndex, offsetBy: labelIndex)])
        } else {
          "\(labelIndex+1)"
        }
      } else {
        ""
      }

      let candidate = candidates[i].precomposedStringWithCanonicalMapping
      let comment = comments[i].precomposedStringWithCanonicalMapping

      let line = NSMutableAttributedString(string: theme.candidateFormat, attributes: labelAttrs)
      let candidateText = NSMutableAttributedString(string: candidate, attributes: attrs)
      if candidate.count <= 5 {
        preventLineBreaks(in: candidateText)
      }
      // Apply semantic accent/warning colors only for non-highlighted rows
      if let inputController, !inputController.specialCommentIndices.isEmpty && i != index {
        if let accent = inputController.specialCommentIndices[.commentHighlight], accent.contains(pageIndex) {
          commentAttrs[.foregroundColor] = theme.accentCommentTextColor
        } else if let warning = inputController.specialCommentIndices[.commentWarning], warning.contains(pageIndex) {
          commentAttrs[.foregroundColor] = theme.warningCommentTextColor
        }
      }
      let labelText = NSAttributedString(string: label, attributes: labelAttrs)
      let commentText = NSAttributedString(string: comment, attributes: commentAttrs)
      replace(placeholder: "[label]", in: line, with: labelText)
      let labeledLine = line.copy() as! NSAttributedString
      replace(placeholder: "[candidate]", in: line, with: candidateText)
      replace(placeholder: "[comment]", in: line, with: commentText)
      if theme.isCapsule {
        // Drop trailing whitespace (e.g. before an empty [comment]) so the panel's right edge hugs the last highlight.
        while line.length > 0, let scalar = UnicodeScalar((line.string as NSString).character(at: line.length - 1)),
              CharacterSet.whitespaces.contains(scalar) {
          line.deleteCharacters(in: NSRange(location: line.length - 1, length: 1))
        }
      }

      if line.length <= 10 {
        preventLineBreaks(in: line)
      }

      let lineSeparator: NSAttributedString
      if isGrid {
        // Rows are paragraphs; cells within a row are aligned by the tab stops set up below.
        lineSeparator = NSAttributedString(string: i % columns == 0 ? "\n" : "\t", attributes: attrs)
      } else if theme.isCapsule {
        // Leave room for the highlight padding on both sides plus a small gap, like the native candidate bar.
        // Built from fixed-width spaces rather than kerning: TextKit attributes part of a kern to the next
        // character's selection rect, which would push the highlight off-center.
        lineSeparator = NSAttributedString(string: spacer(width: theme.capsuleSeparatorWidth, attributes: attrs), attributes: attrs)
      } else {
        lineSeparator = NSAttributedString(string: linear ? "  " : "\n", attributes: attrs)
      }
      if i > 0 {
        text.append(lineSeparator)
      }
      let str = lineSeparator.mutableCopy() as! NSMutableAttributedString
      if vertical {
        str.addAttribute(.verticalGlyphForm, value: 1, range: NSRange(location: 0, length: str.length))
      }
      view.separatorWidth = str.boundingRect(with: .zero).width

      let paragraphStyleCandidate = (i == 0 ? theme.firstParagraphStyle : theme.paragraphStyle).mutableCopy() as! NSMutableParagraphStyle
      if linear {
        paragraphStyleCandidate.paragraphSpacingBefore -= theme.linespace
        paragraphStyleCandidate.lineSpacing = theme.linespace
      }
      if !linear, let labelEnd = labeledLine.string.firstMatch(of: /\[(candidate|comment)\]/)?.range.lowerBound {
        let labelString = labeledLine.attributedSubstring(from: NSRange(location: 0, length: labelEnd.utf16Offset(in: labeledLine.string)))
        let labelWidth = labelString.boundingRect(with: .zero, options: [.usesLineFragmentOrigin]).width
        paragraphStyleCandidate.headIndent = labelWidth
      }
      line.addAttribute(.paragraphStyle, value: paragraphStyleCandidate, range: NSRange(location: 0, length: line.length))

      if isGrid {
        columnWidths[i % columns] = max(columnWidths[i % columns], ceil(line.size().width))
      }
      candidateRanges.append(NSRange(location: text.length, length: line.length))
      text.append(line)
    }

    minTextWidth = 0
    if isGrid, let first = candidateRanges.first {
      // One paragraph style for the whole grid: tab stops at each column's left edge, and room between rows
      // for the highlight padding.
      let gap = theme.capsuleSeparatorWidth
      let style = theme.paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
      style.paragraphSpacingBefore = 0
      style.lineSpacing = 0
      style.headIndent = 0
      style.paragraphSpacing = theme.capsulePadding.height * 2 + 6
      var stops = [NSTextTab]()
      var location: CGFloat = 0
      for width in columnWidths.dropLast() {
        location += width + gap
        stops.append(NSTextTab(textAlignment: .left, location: location))
      }
      style.tabStops = stops
      style.defaultTabInterval = 0
      text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: first.location, length: text.length - first.location))
      minTextWidth = location + (columnWidths.last ?? 0) + 2
    }

    view.textView.textContentStorage?.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)

    // Force TextKit 2 layout before measuring wrapped text and highlight bounds.
    let textWidth = maxTextWidth()
    let maxTextHeight = vertical ? screenRect.width - theme.edgeInset.width * 2 : screenRect.height - theme.edgeInset.height * 2
    view.textContainer.size = NSSize(width: textWidth, height: maxTextHeight)
    view.textLayoutManager.ensureLayout(for: view.textLayoutManager.documentRange)

    // Keep very tall wrapped text from auto-scrolling past the first line.
    view.textView.scrollToBeginningOfDocument(nil)

    view.isGrid = isGrid
    view.drawView(candidateRanges: candidateRanges, hilightedIndex: index, preeditRange: preeditRange, highlightedPreeditRange: highlightedPreeditRange, canPageUp: page > 0, canPageDown: !lastPage)
    show()
  }

  func updateStatus(long longMessage: String, short shortMessage: String) {
    let theme = view.currentTheme
    switch theme.statusMessageType {
    case .mix:
      statusMessage = shortMessage.isEmpty ? longMessage : shortMessage
    case .long:
      statusMessage = longMessage
    case .short:
      if !shortMessage.isEmpty {
        statusMessage = shortMessage
      } else if let initial = longMessage.first {
        statusMessage = String(initial)
      } else {
        statusMessage = ""
      }
    }
  }

  func load(config: SquirrelConfig, forDarkMode isDark: Bool) {
    if isDark {
      view.darkTheme = SquirrelTheme()
      view.darkTheme.load(config: config, dark: true)
    } else {
      view.lightTheme = SquirrelTheme()
      view.lightTheme.load(config: config, dark: isDark)
    }
  }
}

private extension SquirrelPanel {
  func mousePosition() -> NSPoint {
    var point = NSEvent.mouseLocation
    point = self.convertPoint(fromScreen: point)
    return view.convert(point, from: nil)
  }

  func currentScreen() {
    if let screen = NSScreen.main {
      screenRect = screen.frame
    }
    for screen in NSScreen.screens where screen.frame.contains(position.origin) {
      screenRect = screen.frame
      break
    }
  }

  func maxTextWidth() -> CGFloat {
    let theme = view.currentTheme
    let font: NSFont = theme.font
    let fontScale = font.pointSize / 12
    let textWidthRatio = min(1, 1 / (vertical ? 4 : 3) + fontScale / 12)
    let maxWidth = if vertical {
      screenRect.height * textWidthRatio - theme.edgeInset.height * 2
    } else {
      screenRect.width * textWidthRatio - theme.edgeInset.width * 2
    }
    return max(maxWidth, min(minTextWidth, screenRect.width * 0.9))
  }

  // swiftlint:disable:next cyclomatic_complexity
  func show() {
    currentScreen()
    let theme = view.currentTheme
    if theme.native || view.darkTheme.available {
      self.appearance = NSApp.effectiveAppearance
    } else {
      // user configured only a light theme, set window appearance to light.
      self.appearance = NSAppearance(named: .aqua)
    }

    view.textView.textContainerInset = theme.edgeInset

    var textWidth = maxTextWidth()
    // Measure natural text height before constraining the panel.
    view.textContainer.size = NSSize(width: textWidth, height: .greatestFiniteMagnitude)

    // Do not let NSTextView shrink the container to the current view width; it can loop or hide text.
    view.textContainer.widthTracksTextView = false
    view.textContainer.heightTracksTextView = false

    view.textLayoutManager.ensureLayout(for: view.textLayoutManager.documentRange)
    view.textView.bounds.origin = .zero

    var contentRect = view.contentRect

    // Compute the largest size possible for a giant panel
    var naturalPanelSize = NSSize.zero
    if vertical {
      naturalPanelSize.width = contentRect.height + theme.edgeInset.height * 2
      naturalPanelSize.height = contentRect.width + theme.edgeInset.width * 2 + theme.pagingOffset
    } else {
      naturalPanelSize.width = contentRect.width + theme.edgeInset.width * 2 + theme.pagingOffset
      naturalPanelSize.height = contentRect.height + theme.edgeInset.height * 2
    }

    let maxAllowedWidth = screenRect.width * 0.95
    let maxAllowedHeight = screenRect.height * 0.95

    let requiresFullScreen = naturalPanelSize.width > maxAllowedWidth || naturalPanelSize.height > maxAllowedHeight

    if requiresFullScreen {
      // Expand line length before fullscreen scaling to avoid wasting screen space on narrow text.
      let area = contentRect.width * contentRect.height
      let screenRatio = maxAllowedWidth / maxAllowedHeight

      let optimalTextWidth: CGFloat
      if vertical {
        // Width = screen height in vertical mode
        optimalTextWidth = sqrt(area / screenRatio)
      } else {
        optimalTextWidth = sqrt(area * screenRatio)
      }

      // If there's extra room for text, tighten the layout
      if optimalTextWidth > textWidth {
        textWidth = optimalTextWidth
        view.textContainer.size = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        view.textLayoutManager.ensureLayout(for: view.textLayoutManager.documentRange)

        contentRect = view.contentRect

        if vertical {
          naturalPanelSize.width = contentRect.height + theme.edgeInset.height * 2
          naturalPanelSize.height = contentRect.width + theme.edgeInset.width * 2 + theme.pagingOffset
        } else {
          naturalPanelSize.width = contentRect.width + theme.edgeInset.width * 2 + theme.pagingOffset
          naturalPanelSize.height = contentRect.height + theme.edgeInset.height * 2
        }
      }
    }

    if theme.isCapsule && !requiresFullScreen {
      // Whole points keep the size stable between redraws, so unchanged content never starts a size animation.
      naturalPanelSize = NSSize(width: ceil(naturalPanelSize.width), height: ceil(naturalPanelSize.height))
    }

    var panelRect = NSRect.zero

    if requiresFullScreen {
      let scaleX = maxAllowedWidth / naturalPanelSize.width
      let scaleY = maxAllowedHeight / naturalPanelSize.height
      let scale = min(scaleX, scaleY)

      panelRect.size = NSSize(width: naturalPanelSize.width * scale, height: naturalPanelSize.height * scale)

      panelRect.origin = NSPoint(
        x: screenRect.minX + (screenRect.width - panelRect.width) / 2,
        y: screenRect.minY + (screenRect.height - panelRect.height) / 2
      )

      maxHeight = 0
    } else {
      if theme.memorizeSize && (vertical && position.midY / screenRect.height < 0.5) ||
          (vertical && position.minX + max(contentRect.width, maxHeight) + theme.edgeInset.width * 2 > screenRect.maxX) {
        if contentRect.width >= maxHeight {
          maxHeight = contentRect.width
        } else {
          contentRect.size.width = maxHeight
          if vertical {
            naturalPanelSize.height = contentRect.width + theme.edgeInset.width * 2 + theme.pagingOffset
          } else {
            naturalPanelSize.width = contentRect.width + theme.edgeInset.width * 2 + theme.pagingOffset
          }
        }
      }

      panelRect.size = naturalPanelSize

      if vertical {
        // Anchor vertical panels on one side of the cursor to avoid jumping while typing.
        if position.midY / screenRect.height >= 0.5 {
          panelRect.origin.y = position.minY - SquirrelTheme.offsetHeight - panelRect.height + theme.pagingOffset
        } else {
          panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
        }
        panelRect.origin.x = position.minX - panelRect.width - SquirrelTheme.offsetHeight
        if view.preeditRange.length > 0, let preeditTextRange = view.convert(range: view.preeditRange) {
          let preeditRect = view.contentRect(range: preeditTextRange)
          panelRect.origin.x += preeditRect.height + theme.edgeInset.width
        }
      } else {
        panelRect.origin = NSPoint(x: position.minX - theme.pagingOffset, y: position.minY - SquirrelTheme.offsetHeight - panelRect.height)
      }

      if panelRect.maxX > screenRect.maxX { panelRect.origin.x = screenRect.maxX - panelRect.width }
      if panelRect.minX < screenRect.minX { panelRect.origin.x = screenRect.minX }
      if panelRect.minY < screenRect.minY {
        if vertical { panelRect.origin.y = screenRect.minY } else { panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight }
      }
      if panelRect.maxY > screenRect.maxY { panelRect.origin.y = screenRect.maxY - panelRect.height }
      if panelRect.minY < screenRect.minY { panelRect.origin.y = screenRect.minY }
    }

    // Animate size changes of a visible capsule panel whose top-left corner stays put: the window takes the
    // larger of the shown and the new size, and the drawn background and text clip ease towards the new size.
    let shownSize = reveal.map { revealSize($0, at: CACurrentMediaTime()) } ?? frame.size
    let sizeChanged = abs(shownSize.width - panelRect.width) > 1 || abs(shownSize.height - panelRect.height) > 1
    if isVisible && sizeChanged && theme.isCapsule && theme.pagingOffset == 0 && !requiresFullScreen &&
        abs(frame.minX - panelRect.minX) < 0.5 && abs(frame.maxY - panelRect.maxY) < 0.5 {
      let fromRadius = view.revealRadius ?? view.capsuleRadius(for: shownSize)
      let width = max(shownSize.width, panelRect.width)
      let height = max(shownSize.height, panelRect.height)
      let windowRect = NSRect(x: panelRect.minX, y: panelRect.maxY - height, width: width, height: height)
      layout(frame: windowRect, naturalSize: windowRect.size)
      startReveal(Reveal(from: shownSize, to: panelRect.size, fromRadius: fromRadius, toRadius: view.capsuleRadius(for: panelRect.size),
                         start: CACurrentMediaTime(), duration: abs(shownSize.height - panelRect.height) > 0.5 ? 0.22 : 0.14,
                         finalFrame: panelRect, naturalSize: naturalPanelSize))
    } else {
      stopReveal()
      layout(frame: panelRect, naturalSize: naturalPanelSize)
    }
    // Draw now, in the same frame as the window resize, so stale layers are never shown at the new size.
    view.displayIfNeeded()

    alphaValue = theme.alpha
    invalidateShadow()
    orderFront(nil)
    // voila!
  }

  func layout(frame frameRect: NSRect, naturalSize: NSSize) {
    let theme = view.currentTheme
    self.setFrame(frameRect, display: true)

    // Keep the window frame at the scaled physical size while drawing in natural coordinates through bounds.
    contentView!.frame = NSRect(origin: .zero, size: frameRect.size)
    contentView!.bounds = NSRect(origin: .zero, size: naturalSize)

    if vertical {
      contentView!.boundsRotation = -90
      contentView!.setBoundsOrigin(NSPoint(x: 0, y: naturalSize.width))
    } else {
      contentView!.boundsRotation = 0
      contentView!.setBoundsOrigin(.zero)
    }

    view.textView.boundsRotation = 0
    view.textView.setBoundsOrigin(.zero)

    // Subviews must read the post-rotation bounds; Cocoa adjusts the origin and swaps dimensions in vertical mode.
    let subviewFrame = contentView!.bounds
    view.frame = subviewFrame

    var textFrame = subviewFrame
    textFrame.size.width -= theme.pagingOffset
    textFrame.origin.x += theme.pagingOffset
    view.textView.frame = textFrame

    if theme.translucency {
      var backFrame = subviewFrame
      backFrame.size.width += theme.pagingOffset
      back.frame = backFrame
      back.appearance = NSApp.effectiveAppearance
      back.isHidden = false
    } else {
      back.isHidden = true
    }
  }

  func startReveal(_ animation: Reveal) {
    Self.logger.debug("size animation \(animation.from.debugDescription, privacy: .public) -> \(animation.to.debugDescription, privacy: .public)")
    reveal = animation
    applyReveal(at: animation.start)
    if revealTimer == nil {
      let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
        guard let self, let reveal = self.reveal else { return }
        let now = CACurrentMediaTime()
        if now - reveal.start >= reveal.duration {
          self.stopReveal()
          self.layout(frame: reveal.finalFrame, naturalSize: reveal.naturalSize)
          self.view.displayIfNeeded()
          self.invalidateShadow()
        } else {
          self.applyReveal(at: now)
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      revealTimer = timer
    }
  }

  func stopReveal() {
    revealTimer?.invalidate()
    revealTimer = nil
    reveal = nil
    if view.revealSize != nil {
      view.revealSize = nil
      view.revealRadius = nil
      view.needsDisplay = true
    }
  }

  func revealProgress(_ animation: Reveal, at time: CFTimeInterval) -> CGFloat {
    let t = min(1, max(0, (time - animation.start) / animation.duration))
    return 1 - pow(1 - t, 3)  // ease out
  }

  func revealSize(_ animation: Reveal, at time: CFTimeInterval) -> NSSize {
    let p = revealProgress(animation, at: time)
    return NSSize(width: animation.from.width + (animation.to.width - animation.from.width) * p,
                  height: animation.from.height + (animation.to.height - animation.from.height) * p)
  }

  func applyReveal(at time: CFTimeInterval) {
    guard let animation = reveal else { return }
    let p = revealProgress(animation, at: time)
    view.revealSize = revealSize(animation, at: time)
    view.revealRadius = animation.fromRadius + (animation.toRadius - animation.fromRadius) * p
    view.needsDisplay = true
    view.displayIfNeeded()
    invalidateShadow()
  }

  func show(status message: String) {
    let theme = view.currentTheme
    minTextWidth = 0
    view.isGrid = false
    let text = NSMutableAttributedString(string: message, attributes: theme.attrs)
    text.addAttribute(.paragraphStyle, value: theme.paragraphStyle, range: NSRange(location: 0, length: text.length))
    view.textContentStorage.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    view.drawView(candidateRanges: [NSRange(location: 0, length: text.length)], hilightedIndex: -1,
                  preeditRange: .empty, highlightedPreeditRange: .empty, canPageUp: false, canPageDown: false)
    show()

    statusTimer?.invalidate()
    statusTimer = Timer.scheduledTimer(withTimeInterval: SquirrelTheme.showStatusDuration, repeats: false) { _ in
      self.hide()
    }
  }

  func replace(placeholder: String, in text: NSMutableAttributedString, with replacement: NSAttributedString) {
    let string = text.string
    for range in string.ranges(of: placeholder).reversed() {
      text.replaceCharacters(in: convert(range: range, in: string), with: replacement)
    }
  }

  func spacer(width target: CGFloat, attributes: [NSAttributedString.Key: Any]) -> String {
    let spaces = ["\u{2003}", "\u{2002}", "\u{2004}", "\u{2005}", "\u{2009}", "\u{200A}"].map {
      ($0, NSAttributedString(string: $0, attributes: attributes).size().width)
    }
    var result = ""
    var remaining = target
    for (space, width) in spaces where width > 0 {
      while remaining - width >= -width / 2 {
        result += space
        remaining -= width
      }
    }
    return result.isEmpty ? " " : result
  }

  func preventLineBreaks(in text: NSMutableAttributedString) {
    let string = text.string
    let range = convert(range: string.dropFirst().startIndex..<string.endIndex, in: string)
    text.addAttribute(.noBreak, value: true, range: range)
  }

  func convert(range: Range<String.Index>, in string: String) -> NSRange {
    let startPos = range.lowerBound.utf16Offset(in: string)
    let endPos = range.upperBound.utf16Offset(in: string)
    return NSRange(location: startPos, length: endPos - startPos)
  }

  static func makeBackgroundView() -> NSView {
    if #available(macOS 26.0, *) {
      let glassView = NSGlassEffectView()
      glassView.style = .clear
      return glassView
    } else {
      let visualEffectView = NSVisualEffectView()
      visualEffectView.blendingMode = .behindWindow
      visualEffectView.material = .hudWindow
      visualEffectView.state = .active
      return visualEffectView
    }
  }
}
