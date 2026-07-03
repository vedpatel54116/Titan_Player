import Foundation
let lock = NSLock()
lock.withLock { print("locked") }
