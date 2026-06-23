// Camera permission helper. Wraps `AVCaptureDevice` so the UI only
// deals with three states: not-determined, authorized, denied.
// `restricted` (parental controls / MDM) is folded into denied; the
// remediation flow is identical.

import AVFoundation
import Foundation

enum CameraPermissionState: Equatable {
    case notDetermined
    case authorized
    case denied
}

enum CameraPermission {
    static var current: CameraPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:                return .authorized
        case .notDetermined:             return .notDetermined
        case .denied, .restricted:       return .denied
        @unknown default:                return .denied
        }
    }

    /// Request camera access. Returns the new state after the prompt.
    /// Safe to call multiple times; iOS will only show the prompt once,
    /// subsequent calls return the cached decision immediately.
    static func request() async -> CameraPermissionState {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        return granted ? .authorized : .denied
    }
}
