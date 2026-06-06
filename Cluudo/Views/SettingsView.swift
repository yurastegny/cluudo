import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var manager: WeatherManager

    @State private var launchAtLogin = false
    @State private var highlightedSuggestion: Int = -1
    @State private var keyMonitor: Any?
    @FocusState private var locationFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Settings")
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(.primary)

            VStack(alignment: .leading, spacing: 15) {
                toggleRow("Launch at Login", isOn: $launchAtLogin)
                toggleRow("Show weather icon in menu bar", isOn: showMenuBarIconBinding)
                toggleRow("Notify about precipitation", isOn: precipNotificationsBinding)
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Location")

                toggleRow("Auto-detect location", isOn: autoLocationBinding)

                TextField("London, 94103, 48.8566,2.3522", text: locationBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($locationFocused)
                    .inputFieldChrome(focused: locationFocused && !manager.autoLocation)
                    .disabled(manager.autoLocation)
                    .opacity(manager.autoLocation ? 0.4 : 1)
                    .overlay(alignment: .topLeading) {
                        if !manager.locationSuggestions.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(Array(manager.locationSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                                    Button {
                                        manager.chooseLocationSuggestion(suggestion)
                                        highlightedSuggestion = -1
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "mappin")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(.secondary)
                                                .frame(width: 14)
                                            Text(suggestion.displayName)
                                                .font(.system(size: 12))
                                                .lineLimit(1)
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                        .padding(.vertical, 6)
                                        .padding(.horizontal, 8)
                                        .background(index == highlightedSuggestion ? Color.accentColor.opacity(0.15) : Color.clear)
                                    }
                                    .buttonStyle(.plain)

                                    if suggestion.id != manager.locationSuggestions.last?.id {
                                        Divider()
                                    }
                                }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color(nsColor: .secondaryLabelColor).opacity(0.45), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .offset(y: 36)
                        }
                    }
            }
            .zIndex(manager.locationSuggestions.isEmpty ? 0 : 1)

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Units")

                HStack(alignment: .top, spacing: 52) {
                    VStack(alignment: .leading, spacing: 10) {
                        radioRow("Fahrenheit (°F)", isSelected: !manager.useCelsius) {
                            manager.updateUseCelsius(false)
                        }
                        radioRow("Celsius (°C)", isSelected: manager.useCelsius) {
                            manager.updateUseCelsius(true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        radioRow("km/h", isSelected: manager.useKmhWind) {
                            manager.updateUseKmhWind(true)
                        }
                        radioRow("m/s", isSelected: !manager.useKmhWind) {
                            manager.updateUseKmhWind(false)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Icons")

                VStack(alignment: .leading, spacing: 10) {
                    radioRow("Colorful", isSelected: !manager.useMonochromeWeatherIcons) {
                        manager.updateUseMonochromeWeatherIcons(false)
                    }
                    radioRow("Monochrome", isSelected: manager.useMonochromeWeatherIcons) {
                        manager.updateUseMonochromeWeatherIcons(true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text("Weather data provided by ")
                        .font(.system(size: 17))
                        .foregroundColor(.primary)
                    externalLink("MET Norway", url: "https://www.met.no/")
                }

                HStack(spacing: 0) {
                    Text("Thanks to ")
                        .font(.system(size: 17))
                        .foregroundColor(.primary)
                    externalLink("Weather Icons", url: "https://github.com/Makin-Things/weather-icons")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 22)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .frame(width: 380, height: 604, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            locationFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard !manager.locationSuggestions.isEmpty else { return event }
                let count = manager.locationSuggestions.count
                switch event.keyCode {
                case 125: // ↓
                    highlightedSuggestion = min(highlightedSuggestion + 1, count - 1)
                    return nil
                case 126: // ↑
                    highlightedSuggestion = max(highlightedSuggestion - 1, -1)
                    return nil
                case 36: // ↩ Enter
                    guard highlightedSuggestion >= 0 else { return event }
                    manager.chooseLocationSuggestion(manager.locationSuggestions[highlightedSuggestion])
                    highlightedSuggestion = -1
                    return nil
                default:
                    return event
                }
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
        .onChange(of: manager.locationSuggestions) { _ in
            highlightedSuggestion = -1
        }
        .onChange(of: locationFocused) { focused in
            if !focused { manager.locationSuggestions = [] }
        }
        .onChange(of: launchAtLogin) { enabled in
            applyLaunchAtLogin(enabled)
        }
    }

    private var locationBinding: Binding<String> {
        Binding(
            get: {
                if !manager.locationDisplayName.isEmpty {
                    return manager.locationDisplayName
                }
                return manager.location == "auto:ip" ? "" : manager.location
            },
            set: { manager.updateLocationInput($0) }
        )
    }

    private var useCelsiusBinding: Binding<Bool> {
        Binding(
            get: { manager.useCelsius },
            set: { manager.updateUseCelsius($0) }
        )
    }

    private var showMenuBarIconBinding: Binding<Bool> {
        Binding(
            get: { manager.showMenuBarIcon },
            set: { manager.updateShowMenuBarIcon($0) }
        )
    }

    private var autoLocationBinding: Binding<Bool> {
        Binding(
            get: { manager.autoLocation },
            set: { manager.updateAutoLocation($0) }
        )
    }

    private var precipNotificationsBinding: Binding<Bool> {
        Binding(
            get: { manager.precipNotifications },
            set: { newValue in
                if newValue {
                    manager.requestNotificationPermission { granted in
                        manager.precipNotifications = granted
                    }
                } else {
                    manager.precipNotifications = false
                }
            }
        )
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(.primary)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: 17))
                .foregroundColor(.primary)
            Spacer(minLength: 16)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.92)
        }
    }

    private func radioRow(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 1.3)
                        .frame(width: 16, height: 16)
                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 16, height: 16)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 5, height: 5)
                    }
                }

                Text(title)
                    .font(.system(size: 17))
                    .foregroundColor(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func externalLink(_ title: String, url: String) -> some View {
        Button(title) {
            NSWorkspace.shared.open(URL(string: url)!)
        }
        .font(.system(size: 17))
        .foregroundColor(.accentColor)
        .buttonStyle(.plain)
    }

    private func applyLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[Cluudo] Launch at login: \(error)")
        }
    }
}

private extension View {
    func inputFieldChrome(focused: Bool = false) -> some View {
        self
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        focused ? Color.accentColor : Color(nsColor: .secondaryLabelColor).opacity(0.75),
                        lineWidth: focused ? 2 : 1
                    )
            )
            .shadow(color: focused ? Color.accentColor.opacity(0.2) : .clear, radius: 3)
    }
}
