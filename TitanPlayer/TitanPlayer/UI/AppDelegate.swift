//
//  AppDelegate.swift
//  TitanPlayer
//
//  Handles macOS application lifecycle events including file opening
//  from Finder, URL schemes, and deferred file opens on cold launch.
//

import AppKit
import SwiftUI
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    private let logger = Logger(subsystem: "com.titanplayer.app", category: "AppDelegate")

    /// Session reference injected from TitanPlayerApp for file-open forwarding.
    weak var session: PlaybackSession?

    /// URLs received before the session is ready (cold launch from Finder).
    private var pendingFileURLs: [URL] = []

    /// Whether the session has been injected and is ready to receive files.
    private var isSessionReady = false

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Register global keyboard shortcuts
        ShortcutManager.shared.registerGlobalShortcuts()

        // Restore library from disk
        LibraryStore.shared.restore()

        // Set up telemetry opt-in if not already configured
        if !TelemetryManager.shared.hasRecordedConsent {
            // Consent dialog is shown via SwiftUI sheet in ContentView
        }

        // Register for URL scheme events (titanplayer://)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        logger.info("AppDelegate: applicationDidFinishLaunching complete")

        // Process any files that arrived before the session was ready
        flushPendingFiles()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Return false so the app stays in the Dock when the window is closed.
        // This allows files to be opened from Finder without a full app restart.
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Persist library state
        LibraryStore.shared.save()

        // Stop any active playback
        session?.stopPlayback()

        logger.info("AppDelegate: applicationWillTerminate")
    }

    // MARK: - File Opening from Finder (CRITICAL — was missing)

    /// Called by macOS when the user opens files with Titan Player
    /// (double-click in Finder, "Open With", drag onto Dock icon, etc.)
    func application(_ application: NSApplication, open urls: [URL]) {
        logger.info("AppDelegate: application(_:open:) received \(urls.count) URL(s)")

        for url in urls {
            logger.info("  → \(url.absoluteString)")
        }

        guard let session = session else {
            // Session not ready yet — queue for later
            logger.warning("AppDelegate: Session not ready, queuing \(urls.count) URL(s)")
            pendingFileURLs.append(contentsOf: urls)
            return
        }

        openFiles(urls, in: session)
    }

    /// Called when the app is activated (e.g., user clicks Dock icon).
    /// If there are pending files, open them now.
    func applicationDidBecomeActive(_ notification: Notification) {
        flushPendingFiles()
    }

    // MARK: - URL Scheme Handling

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            logger.error("AppDelegate: Failed to parse URL from Apple Event")
            return
        }

        logger.info("AppDelegate: Received URL scheme: \(url.absoluteString)")

        // Handle titanplayer://open?path=/path/to/video.mp4
        if url.scheme == "titanplayer", url.host == "open" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let path = components?.queryItems?.first(where: { $0.name == "path" })?.value {
                let fileURL = URL(fileURLWithPath: path)
                application(NSApp, open: [fileURL])
            }
        }
    }

    // MARK: - File Opening Logic

    /// Inject the session reference from TitanPlayerApp.
    func injectSession(_ session: PlaybackSession) {
        self.session = session
        isSessionReady = true
        logger.info("AppDelegate: Session injected and ready")
        flushPendingFiles()
    }

    /// Open an array of file URLs in the player.
    private func openFiles(_ urls: [URL], in session: PlaybackSession) {
        // Filter to only supported media files
        let supportedURLs = urls.filter { url in
            let isValid = isSupportedMediaFile(url)
            if !isValid {
                logger.warning("AppDelegate: Skipping unsupported file: \(url.lastPathComponent)")
            }
            return isValid
        }

        guard let firstURL = supportedURLs.first else {
            logger.warning("AppDelegate: No supported media files in open request")
            showErrorAlert(
                title: "Unsupported File",
                message: "The selected file(s) are not supported media formats."
            )
            return
        }

        // If multiple files, add the rest to the library/playlist
        if supportedURLs.count > 1 {
            let additionalURLs = Array(supportedURLs.dropFirst())
            LibraryStore.shared.addItems(additionalURLs)
            logger.info("AppDelegate: Added \(additionalURLs.count) additional file(s) to library")
        }

        // Open the first file in the player
        Task { @MainActor in
            // Bring the main window to front
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                window.makeKeyAndOrderFront(nil)
            }

            do {
                try await session.openFile(url: firstURL)
                logger.info("AppDelegate: Successfully opened \(firstURL.lastPathComponent)")
            } catch {
                logger.error("AppDelegate: Failed to open \(firstURL.lastPathComponent): \(error)")
                showErrorAlert(
                    title: "Cannot Open File",
                    message: "Failed to open \"\(firstURL.lastPathComponent)\": \(error.localizedDescription)"
                )
            }
        }
    }

    /// Flush any URLs that arrived before the session was ready.
    private func flushPendingFiles() {
        guard isSessionReady, let session = session, !pendingFileURLs.isEmpty else { return }

        let urls = pendingFileURLs
        pendingFileURLs.removeAll()

        logger.info("AppDelegate: Flushing \(urls.count) pending file(s)")
        openFiles(urls, in: session)
    }

    // MARK: - Validation

    /// Check if a URL points to a supported media file.
    private func isSupportedMediaFile(_ url: URL) -> Bool {
        let supportedExtensions: Set<String> = [
            // Video
            "mp4", "m4v", "mov", "mkv", "webm", "flv", "ts", "mts", "m2ts",
            "avi", "wmv", "mpg", "mpeg", "3gp", "3g2", "ogv", "vob",
            "rm", "rmvb", "asf", "divx", "f4v", "hevc", "mxf",
            // Audio
            "mp3", "aac", "flac", "wav", "aiff", "aif", "m4a", "ogg",
            "opus", "wma", "ac3", "eac3", "dts", "alac", "ape", "mpc",
            // Playlist
            "m3u", "m3u8", "pls"
        ]

        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { return false }

        // Verify the file actually exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.warning("AppDelegate: File does not exist: \(url.path)")
            return false
        }

        return true
    }

    // MARK: - Error Display

    private func showErrorAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
