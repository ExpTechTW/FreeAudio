import AppKit
import Combine
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, devices, apps, updates, about

    /// The sidebar's groups: how FreeAudio behaves, and FreeAudio itself.
    static let groups: [[SettingsPage]] = [[.general, .devices, .apps], [.updates, .about]]

    var id: Self { self }
    var title: String { L("settings.page.\(rawValue)") }
    var subtitle: String { L("settings.page.\(rawValue)_subtitle") }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .devices: "hifispeaker.2.fill"
        case .apps: "square.grid.2x2.fill"
        case .updates: "arrow.down.circle.fill"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general, .about: .gray
        case .devices: .blue
        case .apps: .purple
        case .updates: .indigo
        }
    }
}

/// Which page the Settings window shows.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: "settings.page") }
    }

    init() {
        page = UserDefaults.standard.string(forKey: "settings.page").flatMap(SettingsPage.init(rawValue:)) ?? .general
    }
}

/// The Settings window, managed directly: SwiftUI's Settings scene doesn't reliably open, or come to the front,
/// from a menu bar app.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    private var closing: NSObjectProtocol?
    private var titleUpdates: AnyCancellable?
    private var models: (audio: AudioController, language: LanguageSettings, updater: Updater)?
    private let navigation = SettingsNavigation()

    /// Hands over what the window shows; done once at launch.
    func configure(audio: AudioController, language: LanguageSettings, updater: Updater) {
        models = (audio, language, updater)
    }

    func show(page: SettingsPage? = nil) {
        guard let models else { return }
        if let page { navigation.page = page }
        let window = self.window ?? makeWindow(models)
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Visible even when macOS doesn't hand FreeAudio the focus.
        window.orderFrontRegardless()
    }

    private func makeWindow(_ models: (audio: AudioController, language: LanguageSettings, updater: Updater)) -> NSWindow {
        let root = SettingsRoot(audio: models.audio, language: models.language, navigation: navigation)
            .environmentObject(models.updater)
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 800, height: 640))
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.setFrameAutosaveName("FreeAudio.settings")
        // The page's name, which NSHostingController doesn't pass on from `navigationTitle`. A new language is
        // published before its strings are in use, so the title is set a moment later.
        titleUpdates = navigation.$page.combineLatest(models.language.$language)
            .receive(on: DispatchQueue.main)
            .sink { [weak window] page, _ in
                MainActor.assumeIsolated { window?.title = page.title }
            }
        // A closed window is let go, so its live pages don't keep redrawing behind the scenes.
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window = nil
                self?.titleUpdates = nil
                if let closing = self?.closing { NotificationCenter.default.removeObserver(closing) }
                self?.closing = nil
            }
        }
        return window
    }
}

private struct SettingsRoot: View {
    @ObservedObject var audio: AudioController
    @ObservedObject var language: LanguageSettings
    @ObservedObject var navigation: SettingsNavigation
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { navigation.page }, set: { if let page = $0 { navigation.page = page } })) {
                ForEach(SettingsPage.groups, id: \.self) { group in
                    Section {
                        ForEach(group) { page in
                            Label {
                                Text(page.title)
                            } icon: {
                                PageIcon(page: page, size: 20)
                            }
                            .tag(page)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .focused($sidebarFocused)
        } detail: {
            Group {
                switch navigation.page {
                case .general: GeneralPage()
                case .devices: DevicesPage()
                case .apps: AppsPage()
                case .updates: UpdatesPage()
                case .about: AboutPage()
                }
            }
            .formStyle(.grouped)
        }
        // The sidebar has the keyboard, as in System Settings, rather than whatever text field comes first.
        .defaultFocus($sidebarFocused, true)
        .environmentObject(audio)
        .environmentObject(language)
        .environment(\.locale, language.language.locale)
        // Rebuilds every string when the language changes.
        .id(language.language)
    }
}

/// A page's symbol on a colored rounded square, as System Settings draws them.
struct PageIcon: View {
    let page: SettingsPage
    let size: CGFloat

    var body: some View {
        Image(systemName: page.symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(page.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The large icon, title and description at the top of a page.
struct PageHeader: View {
    let page: SettingsPage

    var body: some View {
        Section {
            HStack(spacing: 14) {
                PageIcon(page: page, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(page.title).font(.title2.bold())
                    Text(page.subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
