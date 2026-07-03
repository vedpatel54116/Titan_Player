# Extract Underlying OSStatus Error from AVURLAsset

**Date:** 2026-07-02  
**Status:** Approved  

## Problem

When AVFoundation fails to open a file, the generic "Cannot Open" error hides the underlying macOS OSStatus error code. The app currently has no KVO observation of `AVPlayerItem.status`, so if an item fails during loading, the OSStatus detail is lost. This makes it impossible to distinguish codec issues, sandbox issues, or file corruption.

## Design

### 1. New `PlaybackError` case — `PlaybackError.swift`

Add a new case that carries the OSStatus:

```swift
case assetLoadFailedWithStatus(OSStatus, Error)
```

Include it in `errorDescription` with the OSStatus code.

### 2. KVO observation of `AVPlayerItem.status` — `PlaybackEngine.swift`

After `player.replaceCurrentItem(with: item)` (line 112), add a Combine publisher:

```swift
item.publisher(for: \.status)
    .removeDuplicates()
    .sink { [weak self] status in
        guard status == .failed else { return }
        // Extract error
    }
    .store(in: &cancellables)
```

When status becomes `.failed`:
1. Get `item.error` as `NSError`
2. Extract OSStatus: if domain is `NSOSStatusErrorDomain`, use `code`; otherwise look in `userInfo[NSUnderlyingErrorKey]`
3. Log full `NSError.description` and `userInfo` dictionary via `os.Logger`
4. Set `state = .error(...)` and `lastError = .assetLoadFailedWithStatus(osStatus, error)`

### 3. Update error display — `PlaybackSession.swift`

In `describe(error:for:)`, add handling for the new case:

```swift
case .assetLoadFailedWithStatus(let status, let underlying):
    return "Failed to open \"\(name)\": OSStatus \(status) — \(underlying.localizedDescription)"
```

### 4. Console logging

In the status observer callback, log:
- Full `NSError.description` (includes domain, code, userInfo)
- The extracted OSStatus value
- The file URL being loaded

## Files to Modify

| File | Change |
|------|--------|
| `PlaybackError.swift` | Add `.assetLoadFailedWithStatus(OSStatus, Error)` case |
| `PlaybackEngine.swift` | Add KVO observation of `AVPlayerItem.status` after `replaceCurrentItem` |
| `PlaybackSession.swift` | Add `describe(error:for:)` handling for new case |

## Acceptance Criteria

- [x] Error alert displays the underlying OSStatus code (e.g., "OSStatus -12345")
- [x] Console logs full NSError description and userInfo dictionary
- [x] App does not suppress the underlying error
