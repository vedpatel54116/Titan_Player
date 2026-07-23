//
//  TitanPlayerApp.swift
//  TitanPlayer
//
//  Application entry point. Wires up the PlaybackSession, AppDelegate,
//  and handles URL/file-open events at the SwiftUI layer.
//

import SwiftUI
import AppKit
import os.log

@main
struct TitanPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var session = PlaybackSession()
    @StateObject private var telemetry = TelemetryManager.shared
    @StateObject private var library = LibraryStore.shared

    @State private var showPrivacyConsent = false
    @State private var pendingOpenURL: URL?

    private let logger = Logger(subsystem: "com.titanplayer.app", category: "App")

    var body: some Scene {
        // ── Main Player Window ──────────────────────────────────
        WindowGroup("Titan Player", id: "main") {
            ContentView()
                .environmentObject(session)
                .environmentObject(telemetry)
                .environmentObject(library)
                .frame(minWidth: 640, minHeight: 360)
                .onAppear {
                    // Inject session into AppDelegate for Finder file opens
                    appDelegate.injectSession(session)

                    // Show privacy consent if needed
                    if !telemetry.hasRecordedConsent {
                        showPrivacyConsent = true
                    }
                }
                // ── CRITICAL: Handle files opened from Finder ──
                .onOpenURL { url in
                    logger.info("TitanPlayerApp: onOpenURL received: \(url.absoluteString)")
                    handleIncomingURL(url)
                }
                // ── Handle Handoff / Continuity ──
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        handleIncomingURL(url)
                    }
                }
                // ── Privacy Consent Sheet ──
                .sheet(isPresented: $showPrivacyConsent) {
                    PrivacyConsentDialog(telemetry: telemetry)
                }
                // ── Global Error Alert ──
                .alert("Player Engine Error", isPresented: $session.showingEngineError) {
                    Button("OK") { session.dismissEngineError() }
                } message: {
                    Text(session.engineErrorMessage)
                }
        }
        .defaultSize(width: 960, height: 540)
        .commands {
            TitanCommands(session: session)
        }

        // ── Mini Player Window ──────────────────────────────────
        Window("Mini Player", id: "mini") {
            MiniPlayerView()
                .environmentObject(session)
        }
        .windowResizability(.contentSize)

        // ── Library Window ──────────────────────────────────────
        WindowGroup("Library", id: "library", for: URL.self) { $url in
            LibraryView()
                .environmentObject(session)
                .environmentObject(library)
        }

        // ── Preferences ─────────────────────────────────────────
        Settings {
            PreferencesWindow()
                .environmentObject(session)
        }
    }

    // MARK: - URL Handling

    private func handleIncomingURL(_ url: URL) {
        // Handle titanplayer:// URL scheme
        if url.scheme == "titanplayer" {
            handleTitanPlayerURL(url)
            return
        }

        // Handle file:// URLs (from Finder, drag & drop, etc.)
        if url.isFileURL {
            openMediaFile(url)
            return
        }

        // Handle http/https streaming URLs
        if url.scheme == "http" || url.scheme == "https" {
            openStreamingURL(url)
            return
        }

        logger.warning("TitanPlayerApp: Unhandled URL scheme: \(url.scheme ?? "nil")")
    }

    private func handleTitanPlayerURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        switch url.host {
        case "open":
            if let path = components.queryItems?.first(where: { $0.name == "path" })?.value {
                openMediaFile(URL(fileURLWithPath: path))
            }
        case "stream":
            if let streamURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
               let parsed = URL(string: streamURL) {
                openStreamingURL(parsed)
            }
        default:
            logger.warning("TitanPlayerApp: Unknown titanplayer:// host: \(url.host ?? "nil")")
        }
    }

    private func openMediaFile(_ url: URL) {
        logger.info("TitanPlayerApp: Opening media file: \(url.lastPathComponent)")

        Task { @MainActor in
            do {
                try await session.openFile(url: url)
            } catch {
                logger.error("TitanPlayerApp: Failed to open file: \(error)")
                session.showEngineError("Cannot open \"\(url.lastPathComponent)\": \(error.localizedDescription)")
            }
        }
    }

    private func openStreamingURL(_ url: URL) {
        logger.info("TitanPlayerApp: Opening streaming URL: \(url.absoluteString)")

        Task { @MainActor in
            do {
                try await session.openStreamingURL(url)
            } catch {
                logger.error("TitanPlayerApp: Failed to open stream: \(error)")
                session.showEngineError("Cannot open stream: \(error.localizedDescription)")
            }
        }
    }
}
