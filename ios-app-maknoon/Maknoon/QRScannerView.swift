// Live QR scanner backed by AVFoundation, wrapped as a SwiftUI view.
//
// The capture session is created on `viewDidLoad`, started on a
// background queue, and torn down in `viewDidDisappear` so we never
// hold the camera open after the user dismisses the sheet or switches
// to manual entry. Detection callbacks land on the main queue and are
// debounced after the first hit: once a code is captured we stop the
// session so a single QR cannot fire multiple times during the brief
// window before SwiftUI dismisses the view.

// AVFoundation is not yet fully Sendable-annotated. Importing it
// under `@preconcurrency` downgrades the resulting strict-concurrency
// warnings (`Capture of 'session' with non-Sendable type
// 'AVCaptureSession' in a '@Sendable' closure`) to warnings the
// compiler accepts. The runtime semantics are correct — the capture
// session is created on the main thread and start/stop is
// dispatched to a background queue per Apple's own examples.
@preconcurrency import AVFoundation
import SwiftUI

struct QRScannerView: UIViewControllerRepresentable {
    /// Invoked when a QR is recognised. Single-shot by default; in
    /// continuous mode keeps firing for every detected QR (with
    /// adjacent-duplicate suppression so a static QR doesn't flood the
    /// receiver). Multi-frame transport callers want continuous.
    let onCode: (String) -> Void
    var continuous: Bool = false

    func makeUIViewController(context: Context) -> QRScannerController {
        let c = QRScannerController()
        c.onCode = onCode
        c.continuous = continuous
        return c
    }

    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {
        uiViewController.continuous = continuous
    }
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var continuous: Bool = false

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didFire = false
    private var lastFiredPayload: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        didFire = false
        startSession()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    private func setupSession() {
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video) else { return }
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.layer.bounds
        view.layer.addSublayer(layer)

        self.captureSession = session
        self.previewLayer = layer
    }

    private func startSession() {
        guard let session = captureSession, !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    private func stopSession() {
        guard let session = captureSession, session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    // AVCaptureMetadataOutputObjectsDelegate
    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let string = object.stringValue else { return }
        if continuous {
            // Suppress adjacent duplicates so a static QR doesn't fire 30x/s.
            if lastFiredPayload == string { return }
            lastFiredPayload = string
            onCode?(string)
            return
        }
        guard !didFire else { return }
        didFire = true
        stopSession()
        onCode?(string)
    }
}
