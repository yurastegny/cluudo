import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let manager    = WeatherManager()

    // ── Reusable menu items ────────────────────────────────────────────────
    private let cityItem        = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
    private let currentItem     = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updatedItem     = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
    private let hourlySep       = NSMenuItem.separator()
    private var hourlyItems:    [NSMenuItem] = []
    private let forecastSep     = NSMenuItem.separator()
    private var forecastItems:  [NSMenuItem] = []
    private let refreshItem     = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updateItem      = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updateChecker   = UpdateChecker()
    private let popupWidth: CGFloat = 288
    private let didShowInitialSettingsKey = "didShowInitialSettings"

    // ── Lifecycle ──────────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        setupMainMenu()
        setupStatusItem()
        buildMenu()
        manager.onUpdate = { [weak self] in self?.refresh() }
        showSettingsOnFirstLaunch()
        updateChecker.onUpdateAvailable = { [weak self] version in self?.showUpdateItem(version: version) }
        updateChecker.check()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let isUpdateTap = response.notification.request.content.userInfo["action"] as? String == "openReleases"
        if isUpdateTap {
            Task { @MainActor in self.updateChecker.openReleasesPage() }
        }
        completionHandler()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // ── Status bar button ──────────────────────────────────────────────────

    private let barFont = NSFont.systemFont(
        ofSize: NSFont.menuBarFont(ofSize: 0).pointSize + 2,
        weight: .regular
    )

    private func setupStatusItem() {
        guard let btn = statusItem.button else { return }
        btn.attributedTitle = NSAttributedString(string: "—°", attributes: [
            .font: barFont,
            .foregroundColor: NSColor.labelColor,
            .baselineOffset: -1,
        ])
    }

    private func updateStatusBarTitle() {
        guard let btn = statusItem.button else { return }
        if manager.showMenuBarIcon, let current = manager.forecast?.current {
            let slug = manager.meteoconSlug(from: current.condition.icon, isDay: current.isDay == 1)
            let img = NSImage(systemSymbolName: sfSymbolName(for: slug), accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
            img?.isTemplate = true
            btn.image = img
            btn.imagePosition = .imageLeft
        } else {
            btn.image = nil
        }
        btn.attributedTitle = NSAttributedString(string: manager.menuBarTitle, attributes: [
            .font: barFont,
            .foregroundColor: NSColor.labelColor,
            .baselineOffset: -1,
        ])
    }

    // ── Menu skeleton ──────────────────────────────────────────────────────

    private func buildMenu() {
        cityItem.isEnabled    = false
        currentItem.isEnabled = false
        currentItem.isHidden  = true
        cityItem.isHidden     = true
        forecastSep.isHidden  = true
        updatedItem.isEnabled = false

        let menuFont = NSFont.menuFont(ofSize: 16)
        func styled(_ title: String) -> NSAttributedString {
            NSAttributedString(string: title, attributes: [.font: menuFont])
        }

        let settingsItem = NSMenuItem(title: "", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.attributedTitle = styled("Settings…")
        settingsItem.target = self
        settingsItem.isEnabled = true
        let quitItem = NSMenuItem(title: "", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quitItem.attributedTitle = styled("Quit")

        updateItem.action  = #selector(openReleasesPage)
        updateItem.target  = self
        updateItem.isHidden = true

        let menu = NSMenu()
        menu.autoenablesItems = false
        hourlySep.isHidden  = true
        forecastSep.isHidden = true

        for item in [cityItem, currentItem, NSMenuItem.separator(),
                     hourlySep,
                     forecastSep,
                     updatedItem, NSMenuItem.separator(),
                     updateItem,
                     settingsItem, NSMenuItem.separator(),
                     quitItem] as [NSMenuItem] {
            menu.addItem(item)
        }
        statusItem.menu = menu
    }

    // ── Refresh ────────────────────────────────────────────────────────────

    private func refresh() {
        updateStatusBarTitle()

        guard let menu = statusItem.menu else { return }

        // Remove previous dynamic items
        hourlyItems.forEach { menu.removeItem($0) }
        hourlyItems.removeAll()
        forecastItems.forEach { menu.removeItem($0) }
        forecastItems.removeAll()

        if let error = manager.error {
            cityItem.view = nil
            cityItem.title  = error
            cityItem.isHidden = false
            currentItem.isHidden = true
            forecastSep.isHidden = true
            updatedItem.title = ""
            updatedItem.view = nil
            return
        }

        guard let data = manager.forecast else {
            cityItem.view = nil
            cityItem.title   = "Loading…"
            cityItem.isHidden = false
            currentItem.isHidden = true
            forecastSep.isHidden = true
            updatedItem.view = nil
            return
        }

        // Top weather summary
        cityItem.view     = makeWeatherSummaryView(data)
        cityItem.isHidden = false

        currentItem.isHidden = true
        hourlySep.isHidden = true

        // Forecast rows
        let rows = manager.dailyRows(dropFirst: true)
        if !rows.isEmpty {
            forecastSep.isHidden = true
            let insertIdx = menu.index(of: forecastSep) + 1

            let spacer = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            spacer.isEnabled = false
            spacer.view = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: 6))
            menu.insertItem(spacer, at: insertIdx)
            forecastItems.append(spacer)

            for (offset, row) in rows.enumerated() {
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.view = makeForecastRow(row)
                menu.insertItem(item, at: insertIdx + 1 + offset)
                forecastItems.append(item)
            }
        } else {
            forecastSep.isHidden = true
        }

        // Updated time
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        updatedItem.title = ""
        updatedItem.view = makeUpdatedView("Updated at \(fmt.string(from: .now))")
    }

    // ── Actions ────────────────────────────────────────────────────────────

    @objc private func openSettings() {
        manager.settingsController.show(manager: manager)
    }

    @objc private func openReleasesPage() {
        updateChecker.openReleasesPage()
    }

    private func showUpdateItem(version: String) {
        let menuFont = NSFont.menuFont(ofSize: 16)
        let title = NSAttributedString(
            string: "Cluudo \(version) available ↗",
            attributes: [.font: menuFont, .foregroundColor: NSColor.systemBlue]
        )
        updateItem.attributedTitle = title
        updateItem.isHidden = false
    }

    private func showSettingsOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: didShowInitialSettingsKey) else { return }
        UserDefaults.standard.set(true, forKey: didShowInitialSettingsKey)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.manager.settingsController.show(manager: self.manager)
        }
    }

    @objc private func doRefresh() {
        Task { await manager.refresh() }
    }

    private func cityDisplayName(_ data: ForecastResponse) -> String {
        data.location.name.isEmpty ? data.location.region : data.location.name
    }

    // ── Custom views ───────────────────────────────────────────────────────

    private func makeWeatherSummaryView(_ data: ForecastResponse) -> NSView {
        let c = data.current
        let primary   = NSColor.labelColor
        let secondary = NSColor.secondaryLabelColor
        let margin: CGFloat = 16
        let totalW = popupWidth
        let bottomGapBelowHourly: CGFloat = 8
        let totalH: CGFloat = 270 + bottomGapBelowHourly
        let container = NSView(frame: NSRect(x: 0, y: 0, width: totalW, height: totalH))

        let city = NSTextField(labelWithString: cityDisplayName(data))
        city.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        city.textColor = primary
        city.frame = NSRect(x: margin, y: totalH - 34, width: totalW - margin * 2, height: 24)
        container.addSubview(city)

        let slug = manager.meteoconSlug(from: c.condition.icon, isDay: c.isDay == 1)
        container.addSubview(makeIcon(
            frame: NSRect(x: margin, y: totalH - 92, width: 58, height: 58),
            slug: slug,
            monochrome: manager.useMonochromeWeatherIcons
        ))

        let tempTF = NSTextField(labelWithString: manager.displayTemp)
        tempTF.font      = NSFont.systemFont(ofSize: 42, weight: .semibold)
        tempTF.textColor = primary
        tempTF.frame     = NSRect(x: margin, y: totalH - 140, width: 106, height: 52)
        container.addSubview(tempTF)

        func label(_ s: String, x: CGFloat, y: CGFloat, w: CGFloat, size: CGFloat = 16, color: NSColor = primary) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.font      = NSFont.systemFont(ofSize: size, weight: .regular)
            t.textColor = color
            t.frame = NSRect(x: x, y: y, width: w, height: 24)
            return t
        }

        let rightX: CGFloat = 128
        let rightW = totalW - rightX - margin
        var y = totalH - 66
        if let todayRow = manager.dailyRows(dropFirst: false).first {
            container.addSubview(label("\(todayRow.maxT)…\(todayRow.minT)", x: rightX, y: y, w: rightW, color: secondary))
        }
        y -= 24
        container.addSubview(label("Feels like \(manager.displayFeelsLike)", x: rightX, y: y, w: rightW, color: secondary))
        y -= 24
        container.addSubview(label("Humidity \(c.humidity)%", x: rightX, y: y, w: rightW, color: secondary))
        y -= 26
        container.addSubview(label("Wind \(manager.displayWind)", x: rightX, y: y, w: rightW, color: secondary))

        let hourly = manager.hourlyRows()
        let colW: CGFloat = 44
        let colGap: CGFloat = 16
        let hourIconSize: CGFloat = 39
        let hourLabelH: CGFloat = 24
        let hourGap: CGFloat = 2
        let hourIconTempGap: CGFloat = 6
        let sectionH: CGFloat = 96

        container.addSubview(label(c.condition.text, x: margin, y: bottomGapBelowHourly + sectionH + 4, w: totalW - margin * 2, size: 16, color: secondary))
        let contentW = margin + CGFloat(hourly.count) * (colW + colGap) - colGap + margin

        let scrollView = HorizontalScrollView(frame: NSRect(x: 0, y: bottomGapBelowHourly, width: totalW, height: sectionH))
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: sectionH))
        for (i, row) in hourly.enumerated() {
            let x = CGFloat(i) * (colW + colGap) + margin
            let timeY = sectionH - hourLabelH
            let iconY = timeY - hourGap - hourIconSize
            let tempY = iconY - hourIconTempGap - hourLabelH

            let timeTF = label(row.time, x: x, y: timeY, w: colW, size: 16)
            timeTF.alignment = .center
            contentView.addSubview(timeTF)

            let iconX = x + (colW - hourIconSize) / 2
            contentView.addSubview(makeIcon(
                frame: NSRect(x: iconX, y: iconY, width: hourIconSize, height: hourIconSize),
                slug: row.slug,
                monochrome: manager.useMonochromeWeatherIcons
            ))

            let temp = label(row.temp, x: x, y: tempY, w: colW, size: 16)
            temp.alignment = .center
            contentView.addSubview(temp)
        }
        scrollView.documentView = contentView

        scrollView.wantsLayer = true
        let fadeMask = CAGradientLayer()
        fadeMask.frame = CGRect(origin: .zero, size: CGSize(width: totalW, height: sectionH))
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint   = CGPoint(x: 1, y: 0.5)
        let fadeStop = margin / totalW
        fadeMask.locations  = [0, NSNumber(value: fadeStop), NSNumber(value: 1 - fadeStop), 1]
        fadeMask.colors     = [NSColor.clear.cgColor, NSColor.black.cgColor,
                               NSColor.black.cgColor, NSColor.clear.cgColor]
        scrollView.layer?.mask = fadeMask

        container.addSubview(scrollView)

        return container
    }

    private func makeHourlyBlock(_ rows: [(time: String, slug: String, temp: String)]) -> NSView {
        let monoFont = NSFont.systemFont(ofSize: 16, weight: .regular)
        let primary  = NSColor.labelColor
        let secondary = NSColor.secondaryLabelColor

        let lm:    CGFloat = 22
        let rm:    CGFloat = 14
        let colW:  CGFloat = 56
        let totalW = lm + colW * CGFloat(rows.count) + rm

        let vPad:  CGFloat = 6
        let timeH: CGFloat = 22
        let gap1:  CGFloat = 2
        let iconS: CGFloat = 20
        let gap2:  CGFloat = 6
        let tempH: CGFloat = 22
        let totalH = vPad + timeH + gap1 + iconS + gap2 + tempH + vPad

        let container = NSView(frame: NSRect(x: 0, y: 0, width: totalW, height: totalH))

        for (i, row) in rows.enumerated() {
            let colX = lm + CGFloat(i) * colW

            let timeY = totalH - vPad - timeH
            let timeTF = NSTextField(labelWithString: row.time)
            timeTF.font = monoFont; timeTF.textColor = secondary; timeTF.alignment = .left
            timeTF.frame = NSRect(x: colX, y: timeY, width: colW, height: timeH)
            container.addSubview(timeTF)

            let iconY = timeY - gap1 - iconS
            container.addSubview(makeIcon(
                frame: NSRect(x: colX, y: iconY, width: iconS, height: iconS),
                slug: row.slug,
                monochrome: manager.useMonochromeWeatherIcons
            ))

            let tempY = iconY - gap2 - tempH
            let tempTF = NSTextField(labelWithString: row.temp)
            tempTF.font = monoFont; tempTF.textColor = primary; tempTF.alignment = .left
            tempTF.frame = NSRect(x: colX, y: tempY, width: colW, height: tempH)
            container.addSubview(tempTF)
        }

        return container
    }

    private func makeUpdatedView(_ text: String) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: 30))
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        label.textColor = NSColor.secondaryLabelColor
        label.frame = NSRect(x: 16, y: 7, width: popupWidth - 32, height: 18)
        container.addSubview(label)
        return container
    }

    private func makeForecastRow(_ row: (label: String, dayNum: Int, slug: String, maxT: String, minT: String)) -> NSView {
        let monoFont = NSFont.systemFont(ofSize: 16, weight: .regular)
        let primary  = NSColor.labelColor
        let secondary = NSColor.secondaryLabelColor

        let lm: CGFloat = 16
        let totalW = popupWidth
        let iconS: CGFloat = 22
        let rightPadding: CGFloat = 16
        let minW: CGFloat = 46
        let maxW: CGFloat = 44
        let minX: CGFloat = totalW - rightPadding - minW
        let maxX: CGFloat = minX - 38
        let iconX: CGFloat = maxX - 3 - iconS
        let h: CGFloat = 37
        let lineH: CGFloat = 28
        let lineY: CGFloat = (h - lineH) / 2 + 1

        let container = NSView(frame: NSRect(x: 0, y: 0, width: totalW, height: h))

        func tf(_ s: String, align: NSTextAlignment, color: NSColor) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.font = monoFont; t.textColor = color; t.alignment = align
            return t
        }

        let numTF = tf("\(row.dayNum)", align: .left, color: secondary)
        numTF.frame = NSRect(x: lm, y: lineY, width: 30, height: lineH)
        container.addSubview(numTF)

        let dayTF = tf(row.label, align: .left, color: primary)
        let dayWidth = ceil(dayTF.intrinsicContentSize.width) + 4
        dayTF.frame = NSRect(x: numTF.frame.maxX, y: lineY, width: dayWidth, height: lineH)
        container.addSubview(dayTF)

        let iconY = lineY + (lineH - iconS) / 2 + 6
        container.addSubview(makeIcon(
            frame: NSRect(x: iconX, y: iconY, width: iconS, height: iconS),
            slug: row.slug,
            monochrome: manager.useMonochromeWeatherIcons
        ))

        let maxTF = tf(row.maxT, align: .right, color: primary)
        maxTF.frame = NSRect(x: maxX, y: lineY, width: maxW, height: lineH)
        container.addSubview(maxTF)

        let minTF = tf(row.minT, align: .right, color: secondary)
        minTF.frame = NSRect(x: minX, y: lineY, width: minW, height: lineH)
        container.addSubview(minTF)

        return container
    }

}

private final class HorizontalScrollView: NSScrollView {
    private var dragStartX: CGFloat = 0
    private var dragStartOriginX: CGFloat = 0

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        dragStartOriginX = contentView.bounds.origin.x
    }

    override func mouseDragged(with event: NSEvent) {
        let delta = (dragStartX - event.locationInWindow.x) * 0.4
        var origin = contentView.bounds.origin
        origin.x = max(0, min(
            dragStartOriginX + delta,
            (documentView?.frame.width ?? 0) - bounds.width
        ))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let delta = (abs(dx) > abs(dy) ? dx : -dy) * 0.4
        var origin = contentView.bounds.origin
        origin.x = max(0, min(
            origin.x - delta,
            (documentView?.frame.width ?? 0) - bounds.width
        ))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}

private func makeIcon(frame: NSRect, slug: String, monochrome: Bool) -> NSImageView {
    let iv = NSImageView(frame: frame)
    if !monochrome, let image = NSImage(named: slug)?.copy() as? NSImage {
        iv.image = image
        iv.contentTintColor = .labelColor
    } else {
        let image = NSImage(systemSymbolName: sfSymbolName(for: slug), accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: min(frame.width, frame.height), weight: .regular))
        image?.isTemplate = true
        iv.image = image
        iv.contentTintColor = .labelColor
    }
    iv.imageScaling = .scaleProportionallyUpOrDown
    return iv
}

private func sfSymbolName(for slug: String) -> String {
    switch slug {
    case "day":
        return "sun.max.fill"
    case "night":
        return "moon.stars.fill"
    case "cloudy":
        return "cloud.fill"
    case "cloudy-day":
        return "cloud.sun.fill"
    case "cloudy-night":
        return "cloud.moon.fill"
    case "rainy":
        return "cloud.rain.fill"
    case "snowy-1", "snowy-2", "snowy-3":
        return "cloud.snow.fill"
    case "thunder":
        return "cloud.bolt.rain.fill"
    default:
        return "cloud.fill"
    }
}
