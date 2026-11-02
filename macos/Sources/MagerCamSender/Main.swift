import AppKit
import Foundation

@main
enum MagerCamMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") {
            print("""
            MagerCam Sender — native macOS camera source
            Open the app normally for camera selection and Start/Stop controls.
            --self-test                  Run offline protocol and H.264 encoder checks.
            --protocol-self-test         Run only protocol checks (no encoder required).
            --test-pattern --key 123456   Serve synthetic video without camera access.
              --port \(SenderEnvironment.port)                TCP port (bundle default).
              --discovery-port \(SenderEnvironment.discoveryPort)      UDP discovery port (bundle default).
              --width 1280 --height 720  Synthetic frame dimensions (up to 1920×1080).
              --duration 20              Exit after this many seconds (optional).
            """)
            return
        }
        if arguments.contains("--self-test") || arguments.contains("--protocol-self-test") {
            do {
                try StreamServer.selfTest()
                print("PASS: MagerCam protocol checks")
                try CameraSource.annexBSelfTest()
                print("PASS: H.264 Annex-B conversion checks")
                try CameraSource.qualitySelfTest()
                print("PASS: camera format and quality policy checks")
                if !arguments.contains("--protocol-self-test") {
                    try CameraSource.selfTest()
                    print("PASS: H.264 encoder checks")
                }
            } catch {
                fputs("Self-test failed: \(error)\n", stderr)
                exit(1)
            }
            return
        }
        if arguments.contains("--test-pattern") {
            runTestPattern(arguments: arguments)
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    private static func runTestPattern(arguments: [String]) {
        func value(_ option: String) -> String? {
            guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let key = value("--key") ?? ProcessInfo.processInfo.environment["MAGERCAM_KEY"],
              key.utf8.count == 6, key.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(value("--port") ?? String(SenderEnvironment.port)), port > 0,
              let discoveryPort = UInt16(value("--discovery-port") ?? String(SenderEnvironment.discoveryPort)), discoveryPort > 0,
              let width = Int(value("--width") ?? "1280"), (320...1920).contains(width), width.isMultiple(of: 2),
              let height = Int(value("--height") ?? "720"), (240...1080).contains(height), height.isMultiple(of: 2) else {
            fputs("Test pattern requires --key with six digits, valid TCP/discovery ports, and even dimensions within 320×240–1920×1080.\n", stderr)
            exit(2)
        }
        let service = StreamServer(port: port, discoveryPort: discoveryPort, accessCode: key)
        let source = CameraSource(onVideo: { [weak service] video in
            service?.broadcastVideo(configuration: video.configuration, frame: video.data,
                                    pts: video.pts, keyframe: video.keyframe)
        }, onError: { detail in fputs("Encoder error: \(detail)\n", stderr); exit(1) })
        let pattern = CameraInfo(id: "test-pattern", name: "Synthetic test pattern")
        let patternFormat = CaptureFormat(width: width, height: height, fps: 30)
        var status = SenderStatus.make(cameras: [pattern], cameraID: "mac-0",
                                        format: patternFormat)
        status["name"] = "MagerCam Mac test pattern"
        status["port"] = Int(port)
        service.updateStatus(status)
        service.onKeyframeNeeded = { [weak source] in source?.requestKeyframe() }
        service.onClientCount = { count in print("Stream clients: \(count)"); fflush(stdout) }
        service.onError = { detail in
            if detail.hasPrefix("Discovery is unavailable") { fputs("Warning: \(detail)\n", stderr) }
            else { fputs("Server error: \(detail)\n", stderr); exit(1) }
        }
        service.onReady = {
            source.startTestPattern(format: patternFormat) { result in
                switch result {
                case .success:
                    print("Synthetic sender ready on TCP \(port), UDP \(discoveryPort). No camera is in use.")
                    fflush(stdout)
                case .failure(let error): fputs("Test pattern failed: \(error)\n", stderr); exit(1)
                }
            }
        }
        do { try service.start() }
        catch { fputs("Server failed: \(error)\n", stderr); exit(1) }
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let stop = { source.stop(); service.stop(); exit(0) }
        interrupt.setEventHandler(handler: stop)
        terminate.setEventHandler(handler: stop)
        interrupt.resume()
        terminate.resume()
        if let durationText = value("--duration"), let duration = Double(durationText), duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: stop)
        }
        withExtendedLifetime((source, service, interrupt, terminate)) { RunLoop.main.run() }
    }
}
