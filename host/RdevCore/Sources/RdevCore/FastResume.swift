import Foundation
/// Relay peer IDs route traffic; only the verified device and retained delivery state authorize resume.
public enum FastResume {
    public static func accepts(retainedGeneration: Data?, offeredGeneration: Data?, retainedDevice: Data?, authenticatedDevice: Data) -> Bool {
        guard let retainedGeneration, retainedGeneration.count == 16, let retainedDevice,
              retainedDevice.count == 32, authenticatedDevice.count == 32 else { return false }
        return retainedGeneration == offeredGeneration && retainedDevice == authenticatedDevice
    }
}
