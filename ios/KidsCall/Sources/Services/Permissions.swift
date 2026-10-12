import AVFoundation

enum Permissions {
    /// Ask for camera and microphone up front so the first call does not
    /// start with black video while the system prompt is showing.
    static func requestCameraAndMicrophone() async {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }
}
