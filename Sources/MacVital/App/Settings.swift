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
@Observable
final class AppSettings {
    // Stored properties written through to UserDefaults, not `@AppStorage`.
    //
    // `@AppStorage` is a view property wrapper. Inside a class it reads and
    // writes UserDefaults correctly but tells nobody, which made every setting
    // here quietly half-broken: flip the appearance mode in Settings and the
    // main window kept its old colour scheme until something unrelated forced
    // a redraw, because nothing observing this object heard about the change.
    // The note on `currentRetentionDays` below was already describing this.
    //
    // As `@Observable` stored properties every read is tracked and every write
    // notifies. The keys are byte-for-byte the ones `@AppStorage` used, so
    // existing users keep their settings.
    @ObservationIgnored private let defaults: UserDefaults

    var appearanceMode: AppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: Keys.appearanceMode) }
    }
    var showMenuBarSpeed: Bool {
        didSet { defaults.set(showMenuBarSpeed, forKey: Keys.showMenuBarSpeed) }
    }
    var showMenuBarPen: Bool {
        didSet { defaults.set(showMenuBarPen, forKey: Keys.showMenuBarPen) }
    }
    /// Closing the window leaves the app running instead of quitting it.
    ///
    /// On by default because half of what this app does is background work the
    /// window is not needed for: the menu bar throughput readout, the screen
    /// pen hotkey, and the quarantine sweep. Quitting on window close threw all
    /// of that away every time the user tidied up their desktop.
    var keepRunningInBackground: Bool {
        didSet { defaults.set(keepRunningInBackground, forKey: Keys.keepRunningInBackground) }
    }
    var advisorMode: AdvisorMode {
        didSet { defaults.set(advisorMode.rawValue, forKey: Keys.advisorMode) }
    }
    var localModelEndpoint: String {
        didSet { defaults.set(localModelEndpoint, forKey: Keys.localModelEndpoint) }
    }
    var localModelName: String {
        didSet { defaults.set(localModelName, forKey: Keys.localModelName) }
    }
    var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: AppSettings.retentionDaysKey) }
    }
    var largeFileThresholdMB: Int {
        didSet { defaults.set(largeFileThresholdMB, forKey: Keys.largeFileThresholdMB) }
    }
    var projectSearchDepth: Int {
        didSet { defaults.set(projectSearchDepth, forKey: Keys.projectSearchDepth) }
    }
    private var projectRootsRaw: String {
        didSet { defaults.set(projectRootsRaw, forKey: Keys.projectRootsRaw) }
    }

    var hasCloudKey: Bool

    private enum Keys {
        static let appearanceMode = "appearanceMode"
        static let showMenuBarSpeed = "showMenuBarSpeed"
        static let showMenuBarPen = "showMenuBarPen"
        static let keepRunningInBackground = "keepRunningInBackground"
        static let advisorMode = "advisorMode"
        static let localModelEndpoint = "localModelEndpoint"
        static let localModelName = "localModelName"
        static let largeFileThresholdMB = "largeFileThresholdMB"
        static let projectSearchDepth = "projectSearchDepth"
        static let projectRootsRaw = "projectRootsRaw"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // `object(forKey:) as? T` rather than `bool(forKey:)` / `integer(forKey:)`:
        // those return false / 0 for a key that was never written, which would
        // silently replace every default with its zero value on first launch.
        appearanceMode = defaults.string(forKey: Keys.appearanceMode)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system
        showMenuBarSpeed = defaults.object(forKey: Keys.showMenuBarSpeed) as? Bool ?? true
        showMenuBarPen = defaults.object(forKey: Keys.showMenuBarPen) as? Bool ?? true
        keepRunningInBackground = defaults.object(forKey: Keys.keepRunningInBackground) as? Bool ?? true
        advisorMode = defaults.string(forKey: Keys.advisorMode)
            .flatMap(AdvisorMode.init(rawValue:)) ?? .offline
        localModelEndpoint = defaults.string(forKey: Keys.localModelEndpoint)
            ?? "http://127.0.0.1:11434/api/chat"
        localModelName = defaults.string(forKey: Keys.localModelName) ?? "qwen2.5:3b"
        retentionDays = defaults.object(forKey: AppSettings.retentionDaysKey) as? Int
            ?? QuarantineStore.defaultRetentionDays
        largeFileThresholdMB = defaults.object(forKey: Keys.largeFileThresholdMB) as? Int ?? 256
        projectSearchDepth = defaults.object(forKey: Keys.projectSearchDepth) as? Int ?? 5
        projectRootsRaw = defaults.string(forKey: Keys.projectRootsRaw) ?? ""
        hasCloudKey = KeychainStore.has(.anthropicAPIKey)
    }

    nonisolated static let retentionDaysKey = "retentionDays"

    /// The retention window, readable from off the main actor.
    ///
    /// `QuarantineStore` is an actor and stamps an expiry at the moment an item
    /// moves in, so it needs the value that is set *then* — not the one that
    /// happened to be set when `AppSettings` was constructed. This class is
    /// main-actor isolated and the store is not, so it reads the backing
    /// UserDefaults directly — which `retentionDays` writes through to.
    nonisolated static func currentRetentionDays() -> Int {
        let stored = UserDefaults.standard.integer(forKey: retentionDaysKey)
        guard stored > 0 else { return QuarantineStore.defaultRetentionDays }
        return min(stored, 30)
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
        // The steppers enforce these ranges during normal use. Clamp again at
        // the boundary because UserDefaults can be edited independently and an
        // unchecked MB conversion could otherwise overflow Int64.
        let safeDepth = min(max(projectSearchDepth, 2), 8)
        let safeThresholdMB = min(max(largeFileThresholdMB, 50), 4_096)
        return ScanOptions(
            projectRoots: usesDefaultProjectRoots ? nil : projectRoots,
            projectSearchDepth: safeDepth,
            largeFileThreshold: Int64(safeThresholdMB) * 1_000_000
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
