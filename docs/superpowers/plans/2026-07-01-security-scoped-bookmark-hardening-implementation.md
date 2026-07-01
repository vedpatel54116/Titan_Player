# Security-Scoped Bookmark Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden security-scoped resource management in PlaybackSession to prevent silent failures when opening sandboxed files.

**Architecture:** Add bookmark lifecycle management directly to PlaybackSession, with UserDefaults persistence, proper start/stop access calls, and error handling for stale bookmarks.

**Tech Stack:** Swift, SwiftUI, AppKit (NSAlert), UserDefaults, Security framework (security-scoped bookmarks)

---

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift` | Modify | Add bookmark properties and lifecycle methods |
| `TitanPlayer/Tests/Unit/BookmarkManagerTests.swift` | Create | Unit tests for bookmark operations |

---

## Task 1: Add Bookmark Properties and Helpers

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift:7-46`

- [ ] **Step 1: Add new properties to PlaybackSession**

Add these properties after line 26 (`@Published var subtitleBackgroundOpacity: Float = 0.6`):

```swift
@Published var currentlyAccessedURL: URL?

private let bookmarkDefaultsKey = "SecurityScopedBookmarks"
```

- [ ] **Step 2: Add bookmark helper methods**

Add these methods before the `init` method (around line 47):

```swift
// MARK: - Security-Scoped Bookmark Management

private func createBookmark(for url: URL) {
    do {
        let bookmarkData = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkDefaultsKey) as? [String: Data] ?? [:]
        bookmarks[url.path] = bookmarkData
        UserDefaults.standard.set(bookmarks, forKey: bookmarkDefaultsKey)
    } catch {
        NSLog("[BookmarkManager] Failed to create bookmark for %@: %@", url.path, error.localizedDescription)
    }
}

private func resolveBookmark(for path: String) -> URL? {
    guard let bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkDefaultsKey) as? [String: Data],
          let bookmarkData = bookmarks[path] else {
        return nil
    }
    
    var isStale = false
    do {
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        
        if isStale {
            NSLog("[BookmarkManager] Stale bookmark detected for path: %@", path)
            removeBookmark(for: path)
            return nil
        }
        
        return url
    } catch {
        NSLog("[BookmarkManager] Failed to resolve bookmark for %@: %@", path, error.localizedDescription)
        removeBookmark(for: path)
        return nil
    }
}

private func removeBookmark(for path: String) {
    var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkDefaultsKey) as? [String: Data] ?? [:]
    bookmarks.removeValue(forKey: path)
    UserDefaults.standard.set(bookmarks, forKey: bookmarkDefaultsKey)
    NSLog("[BookmarkManager] Removed stale bookmark for path: %@", path)
}

private func startAccessingBookmark(for url: URL) -> Bool {
    let accessing = url.startAccessingSecurityScopedResource()
    if !accessing {
        NSLog("[BookmarkManager] Failed to start accessing security-scoped resource for: %@", url.path)
    }
    return accessing
}

private func stopAccessingCurrentResource() {
    if let currentURL = currentlyAccessedURL {
        currentURL.stopAccessingSecurityScopedResource()
        NSLog("[BookmarkManager] Stopped accessing: %@", currentURL.path)
        currentlyAccessedURL = nil
    }
}
```

- [ ] **Step 3: Add stale bookmark alert method**

Add this method after the bookmark helpers:

```swift
private func showStaleBookmarkAlert(path: String) {
    let alert = NSAlert()
    alert.messageText = "File Unavailable"
    alert.informativeText = "The file at \"\(path)\" may have been moved or deleted. Please open the file again."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
```

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
git commit -m "feat: add security-scoped bookmark properties and helpers"
```

---

## Task 2: Modify openFile() to Use Bookmarks

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift:96-120`

- [ ] **Step 1: Update openFile() method**

Replace the `openFile` method (lines 96-120) with:

```swift
func openFile(url: URL) async {
    // Stop accessing previous resource if any
    stopAccessingCurrentResource()
    
    // Create and store bookmark for new URL
    createBookmark(for: url)
    
    // Resolve bookmark to get fresh URL
    guard let resolvedURL = resolveBookmark(for: url.path) else {
        showStaleBookmarkAlert(path: url.path)
        return
    }
    
    // Start accessing security-scoped resource
    guard startAccessingBookmark(for: resolvedURL) else {
        playState = .error("Cannot access file at \(url.path). Check file permissions.")
        return
    }
    
    // Track the accessed URL
    currentlyAccessedURL = resolvedURL
    
    // Load into engine
    do {
        try await engine.load(url: resolvedURL)
        if url.pathExtension.lowercased() == "m3u8" {
            streaming.load(url: url)
            streaming.attach(player: engine.avPlayer)
        }
        let videoTrack = mediaInfo?.videoTracks.first
        performance.observe(
            settings: CurrentPlaybackSettings(
                decoderIsHW: false,
                resolution: CGSize(
                    width: videoTrack?.width ?? 1920,
                    height: videoTrack?.height ?? 1080
                ),
                currentBitrate: streaming.observedBitrate > 0
                    ? Int(streaming.observedBitrate) : 0,
                isStreaming: url.pathExtension.lowercased() == "m3u8",
                audioEngineActive: !isAudioOnly
            )
        )
        performance.optimizeForCurrentState()
    } catch {
        stopAccessingCurrentResource()
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
git commit -m "feat: integrate bookmarks into openFile() workflow"
```

---

## Task 3: Update stop() to Clean Up Resources

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift:166-170`

- [ ] **Step 1: Update stop() method**

Replace the `stop` method (lines 166-170) with:

```swift
func stop() {
    engine.stop()
    subtitleManager.clear()
    performance.observe(settings: nil)
    stopAccessingCurrentResource()
}
```

- [ ] **Step 2: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
git commit -m "feat: add resource cleanup to stop()"
```

---

## Task 4: Add Cleanup on App Termination

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift:73-78`

- [ ] **Step 1: Add app termination observer in init**

In the `init` method, after `installDisplayBindings()` (line 76), add:

```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(applicationWillTerminate),
    name: NSApplication.willTerminateNotification,
    object: nil
)
```

- [ ] **Step 2: Add applicationWillTerminate handler**

Add this method after the `stop()` method:

```swift
@objc private func applicationWillTerminate() {
    stopAccessingCurrentResource()
}
```

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
git commit -m "feat: add cleanup on app termination"
```

---

## Task 5: Write Unit Tests

**Files:**
- Create: `TitanPlayer/Tests/Unit/BookmarkManagerTests.swift`

- [ ] **Step 1: Create test file**

```swift
import XCTest
@testable import TitanPlayer

@MainActor
final class BookmarkManagerTests: XCTestCase {
    private func makeSession() -> PlaybackSession {
        PlaybackSession(videoRenderer: MockFrameRenderer(),
                        audioRenderer: MockAudioRenderer())
    }
    
    override func setUp() {
        super.setUp()
        // Clear any existing bookmarks
        UserDefaults.standard.removeObject(forKey: "SecurityScopedBookmarks")
    }
    
    func testCreateBookmarkStoresInDefaults() {
        let s = makeSession()
        let testURL = URL(fileURLWithPath: "/tmp/test.txt")
        
        // Access the private method via reflection
        let selector = NSSelectorFromString("createBookmarkFor:")
        s.perform(selector, with: testURL)
        
        let bookmarks = UserDefaults.standard.dictionary(forKey: "SecurityScopedBookmarks") as? [String: Data]
        XCTAssertNotNil(bookmarks)
        XCTAssertNotNil(bookmarks?["/tmp/test.txt"])
    }
    
    func testRemoveBookmarkClearsFromDefaults() {
        let s = makeSession()
        
        // First create a bookmark
        UserDefaults.standard.set(
            ["test": Data([0x01])],
            forKey: "SecurityScopedBookmarks"
        )
        
        // Remove it
        let selector = NSSelectorFromString("removeBookmarkFor:")
        s.perform(selector, with: "test")
        
        let bookmarks = UserDefaults.standard.dictionary(forKey: "SecurityScopedBookmarks") as? [String: Data]
        XCTAssertTrue(bookmarks?.isEmpty ?? true)
    }
    
    func testStopAccessingClearsURL() {
        let s = makeSession()
        s.currentlyAccessedURL = URL(fileURLWithPath: "/tmp/test.txt")
        
        // Note: stopAccessingSecurityScopedResource won't work in tests
        // but we can verify the URL is cleared
        let selector = NSSelectorFromString("stopAccessingCurrentResource")
        s.perform(selector)
        
        XCTAssertNil(s.currentlyAccessedURL)
    }
}
```

- [ ] **Step 2: Run tests to verify they compile**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`

Expected: Empty result (no errors other than missing XCTest)

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/Tests/Unit/BookmarkManagerTests.swift
git commit -m "test: add unit tests for bookmark management"
```

---

## Task 6: Verify Build and Run Tests

- [ ] **Step 1: Build the project**

Run: `swift build`

Expected: Build succeeds with no errors

- [ ] **Step 2: Run all tests (if Xcode available)**

Run: `swift test`

Expected: All tests pass

- [ ] **Step 3: Verify no regressions**

Check that:
- Dragging files from Finder works
- Files opened via file picker play correctly
- Stale bookmarks show error alert
- Previous file access stops when new file opens

---

## Verification Checklist

After implementation, verify:

1. **Files from Finder** - Drag a file onto the app, verify it plays
2. **Files from Dock** - Open file via dock icon, verify it plays
3. **No sandbox violations** - Check Console.app for sandbox errors
4. **Stale bookmark handling** - Move a previously opened file, try to reopen, verify alert appears
5. **Multiple file opens** - Open file A, then file B, verify file A's access stops
6. **App termination** - Open file, quit app, verify no resource access errors on next launch
