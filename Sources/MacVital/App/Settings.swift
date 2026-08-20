import Foundation
import MacVitalKit
import SwiftUI

/// User-visible configuration. The API key is *not* here — it lives in the
/// keychain (see `KeychainStore`) and only its presence is mirrored into
/// `hasCloudKey`.
/// Light / dark. The whole UI is built on semantic colours, so following the
/// system needs no code at all — this exists only so the user can override it
/// per-app, which people expect from a Mac app and cannot do from anywhere else.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// `nil` hands the decision back to SwiftUI, which follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("appearanceMode") var appearanceMode: AppearanceMode = .system
    @AppStorage("showMenuBarSpeed") var showMenuBarSpeed: Bool = true
    @AppStorage("showMenuBarPen") var showMenuBarPen: Bool = true
    /// Closing the window leaves the app running instead of quitting it.
    ///
    /// On by default because half of what this app does is background work the
    /// window is not needed for: the menu bar throughput readout, the screen
    /// pen hotkey, and the quarantine sweep. Quitting on window close threw all
    /// of that away every time the user tidied up their desktop.
    @AppStorage("keepRunningInBackground") var keepRunningInBackground: Bool = true
    @AppStorage("advisorMode") var advisorMode: AdvisorMode = .offline
    @AppStorage("localModelEndpoint") var localModelEndpoint: String = "http://127.0.0.1:11434/api/chat"
    @AppStorage("localModelName") var localModelName: String = "qwen2.5:3b"
    @AppStorage(AppSettings.retentionDaysKey) var retentionDays: Int = QuarantineStore.defaultRetentionDays
    @AppStorage("largeFileThresholdMB") var largeFileThresholdMB: Int = 256
    @AppStorage("projectSearchDepth") var projectSearchDepth: Int = 5
    @AppStorage("projectRootsRaw") private var projectRootsRaw: String = ""

    @Published var hasCloudKey: Bool = KeychainStore.has(.anthropicAPIKey)

    nonisolated static let retentionDaysKey = "retentionDays"

    /// The retention window, readable from off the main actor.
    ///
    /// `QuarantineStore` is an actor and stamps an expiry at the moment an item
    /// moves in, so it needs the value that is set *then* — not the one that
    /// happened to be set when `AppSettings` was constructed. `@AppStorage`
    /// inside an `ObservableObject` publishes nothing, so there is no
    /// notification to subscribe to either; reading the backing store directly
    /// is both the simplest and the only reliably current answer.
    nonisolated static func currentRetentionDays() -> Int {
        let stored = UserDefaults.standard.integer(forKey: retentionDaysKey)
        return stored > 0 ? stored : QuarantineStore.defaultRetentionDays
    }

    var projectRoots: [String] {
        get {
            let stored = projectRootsRaw
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return stored.isEmpty ? ScanOptions().projectRoots : stored
        }
        set { projectRootsRaw = newValue.joined(separator: "\n") }
    }

    var usesDefaultProjectRoots: Bool { projectRootsRaw.isEmpty }

    func setCloudKey(_ key: String?) {
        KeychainStore.set(key, for: .anthropicAPIKey)
        hasCloudKey = KeychainStore.has(.anthropicAPIKey)
        if !hasCloudKey, advisorMode == .cloud { advisorMode = .offline }
    }

    func scanOptions() -> ScanOptions {
        ScanOptions(
            projectRoots: usesDefaultProjectRoots ? nil : projectRoots,
            projectSearchDepth: projectSearchDepth,
            largeFileThreshold: Int64(largeFileThresholdMB) * 1_000_000
        )
    }

    /// Build the advisor the current settings describe. Returns `nil` for the
    /// offline mode, which `CompositeAdvisor` reads as "heuristics only".
    func makeAdvisor() -> AIAdvisor? {
        switch advisorMode {
        case .offline:
            return nil
        case .local:
            guard let url = URL(string: localModelEndpoint) else { return nil }
            return LocalModelAdvisor(
                configuration: .init(endpoint: url, model: localModelName)
            )
        case .cloud:
            guard let key = KeychainStore.get(.anthropicAPIKey), !key.isEmpty else { return nil }
            return CloudAdvisor(configuration: .init(apiKey: key))
        }
    }
}
