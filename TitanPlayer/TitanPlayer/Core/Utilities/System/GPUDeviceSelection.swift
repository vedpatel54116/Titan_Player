import Foundation
import Metal

final class GPUDeviceSelector {
    static let shared = GPUDeviceSelector()

    private init() {}

    var preferredDevice: MTLDevice? {
        if #available(macOS 14.0, *) {
            if let preferredGPU = findExternalGPU() {
                return preferredGPU
            }
        }
        return MTLCreateSystemDefaultDevice()
    }

    var availableDevices: [MTLDevice] {
        MTLCopyAllDevices()
    }

    func findExternalGPU() -> MTLDevice? {
        if #available(macOS 14.0, *) {
            let devices = MTLCopyAllDevices()
            for device in devices where device.isRemovable {
                return device
            }
        }
        return nil
    }

    func selectDevice(preferringLowPower: Bool) -> MTLDevice? {
        let devices = availableDevices
        if preferringLowPower {
            return devices.first(where: { $0.isLowPower }) ?? devices.first
        }
        return devices.first(where: { !$0.isLowPower }) ?? devices.first
    }
}
