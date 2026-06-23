// Local-only share-as-QR. Renders the Presentation as a rotating
// sequence of small QR frames; the verifier's scanner collects frames
// until the source bytes reassemble.
//
// No upload, no third-party infrastructure. The Elabify drop pastebin
// still exists server-side for callers that explicitly want it, but the
// default Share flow uses this local path.

import SwiftUI

struct LocalShareQrSheet: View {
    let presentation: Presentation
    let onClose: () -> Void

    @State private var frames: [LocalFrameEnvelope] = []
    @State private var renderedFrames: [UIImage?] = []
    @State private var currentIndex: Int = 0
    @State private var prepError: String?

    /// Seconds each frame is shown. A browser QR decoder (the React
    /// verifier scans with a webcam) needs a much longer, stable dwell to
    /// lock a dense frame than a native camera does, so the default is
    /// slow and a live slider lets the presenter tune it. Larger = slower
    /// = more reliable capture, at the cost of a longer full cycle.
    @State private var secondsPerFrame: Double = 0.7

    var body: some View {
        NavigationStack {
            Group {
                if let err = prepError {
                    VStack(spacing: 12) {
                        Text(err).foregroundStyle(.red).font(.callout)
                        Button("Close") { onClose() }
                    }
                    .padding()
                } else if let img = currentImage {
                    ScrollView {
                        VStack(spacing: 14) {
                            Image(uiImage: img)
                                .resizable()
                                .interpolation(.none)
                                .aspectRatio(1, contentMode: .fit)
                                .frame(maxWidth: 360)
                                .padding(20)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 16))

                            // A single progress bar (not one dot per frame:
                            // a large transmission has dozens of frames and a
                            // dot row overflows the screen width).
                            ProgressView(value: Double(currentIndex + 1),
                                         total: Double(max(frames.count, 1)))
                                .tint(.purple)
                                .padding(.horizontal, 24)
                                .padding(.top, 4)

                            Text("Frame \(currentIndex + 1) of \(frames.count)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)

                            VStack(spacing: 2) {
                                Text(String(format: "Rotation: %.2fs per frame", secondsPerFrame))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Slider(value: $secondsPerFrame, in: 0.3...1.5, step: 0.05) {
                                    Text("Rotation speed")
                                } minimumValueLabel: {
                                    Image(systemName: "hare")
                                } maximumValueLabel: {
                                    Image(systemName: "tortoise")
                                }
                                .tint(.purple)
                                .padding(.horizontal, 24)
                            }

                            Text("Hold steady. The verifier's wallet collects every frame, then assembles your Presentation locally. No server in the loop. If the scanner is missing frames, slide toward the tortoise.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                                .padding(.top, 4)
                        }
                        .padding(.vertical, 24)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Offline QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onClose() }
                }
            }
            // Drive rotation from an async loop keyed on the slider value:
            // when secondsPerFrame changes the task restarts at the new
            // interval, while currentIndex (a @State) persists.
            .task(id: secondsPerFrame) {
                if frames.isEmpty { prepare() }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(secondsPerFrame * 1_000_000_000))
                    advance()
                }
            }
        }
    }

    private var currentImage: UIImage? {
        guard !renderedFrames.isEmpty else { return nil }
        let i = currentIndex % renderedFrames.count
        return renderedFrames[i]
    }

    private func prepare() {
        guard frames.isEmpty else { return }
        do {
            let json = try JSONEncoder().encode(presentation)
            let envs = LocalFrames.chunks(of: json)
            frames = envs
            // Pre-render every frame so animation is glitch-free.
            renderedFrames = envs.map { LocalFrames.renderFrame($0) }
        } catch {
            prepError = "Could not encode presentation: \(error)"
        }
    }

    private func advance() {
        if frames.isEmpty { return }
        currentIndex = (currentIndex + 1) % frames.count
    }
}
