# Security-Scoped Bookmark Hardening Design

**Date:** 2026-07-01
**Status:** Approved
**Scope:** PlaybackSession bookmark lifecycle management

## Problem

Files dragged from Finder or opened via Dock icon can fail silently if the security-scoped bookmark resolution fails. The current `openFile(url:)` path doesn't create or manage bookmarks, meaning sandboxed access rights are not preserved across sessions.

## Requirements

1. Create security-scoped bookmark when any file is opened
2. Store bookmark in UserDefaults keyed by file path
3. Resolve bookmark and start accessing before playback
4. Stop access when file is closed or app terminates
5. Log error and show modal alert if bookmark resolution fails
6. Remove stale bookmarks from UserDefaults immediately on detection

## Design: Integrated into PlaybackSession

### New Properties

```swift
@Published var currentlyAccessedURL: URL?
private let bookmarkDefaultsKey = "SecurityScopedBookmarks"
```

### Modified: `openFile(url:)`

1. Stop accessing previous resource if any
2. Create security-scoped bookmark from `url`
3. Store bookmark data in UserDefaults under `url.path`
4. Resolve bookmark to get fresh URL
5. Start accessing security-scoped resource
6. Assign resolved URL to `currentlyAccessedURL`
7. Call `engine.load(url:)` with resolved URL

### Modified: `stop()`

1. Stop accessing security-scoped resource
2. Clear `currentlyAccessedURL`

### New Private Methods

| Method | Purpose |
|--------|---------|
| `createBookmark(for:)` | Save bookmark data to UserDefaults |
| `resolveBookmark(for path:) -> URL?` | Resolve stored bookmark, return URL |
| `startAccessingBookmark(for:) -> Bool` | Start accessing security-scoped resource |
| `stopAccessingCurrentResource()` | Stop access and clear state |
| `showStaleBookmarkAlert(path:)` | Show NSAlert for stale bookmarks |
| `removeBookmark(for path:)` | Remove entry from UserDefaults |

### Stale Bookmark Handling

In `openFile()`:
1. Try `resolveBookmark(for: url.path)`
2. If fails → log error, `removeBookmark(for:)`, show modal alert, return
3. If succeeds → start access, continue with playback

### Cleanup Behavior

- Stale bookmarks removed immediately on detection
- Previous file's access stopped when new file opened
- `stop()` cleans up current resource access

### Error Logging

Use `NSLog` or `os_log` with category for bookmark failures:
```
[BookmarkManager] Failed to resolve bookmark for /path/to/file: <error>
[BookmarkManager] Stale bookmark removed for /path/to/file
```

## Files Modified

| File | Changes |
|------|---------|
| `UI/Session/PlaybackSession.swift` | Add bookmark properties, modify `openFile()`, `stop()`, add helper methods |

## Testing

- Unit tests for bookmark CRUD operations
- Integration test for open → stop → open cycle
- Verify stale bookmark cleanup in UserDefaults
- Verify modal alert shown on resolution failure
