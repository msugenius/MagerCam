import AppKit
import AVFoundation
import Darwin
import SwiftUI

enum SenderEnvironment {
    static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "MagerCam Sender"
    static let port = UInt16(exactly: (Bundle.main.object(forInfoDictionaryKey: "MagerCamTCPPort") as? NSNumber)?.intValue ?? 4848) ?? 4848
    static let discoveryPort = UInt16(exactly: (Bundle.main.object(forInfoDictionaryKey: "MagerCamDiscoveryPort") as? NSNumber)?.intValue ?? 4849) ?? 4849
}

enum LocalAddresses {
    static func ipv4() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var addresses: [String] = []
        var cursor = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                           socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: host)
                if !addresses.contains(value) { addresses.append(value) }
            }
        }
        return addresses
    }
}

enum SenderStatus {
    static func make(cameras: [CameraInfo], cameraID: String, format: CaptureFormat,
                     clients: Int = 0) -> [String: Any] {
        [
            "name": Host.current().localizedName ?? "Mac camera", "ver": 2,
            "w": format.width, "h": format.height, "fps": format.fps,
            "sizes": ["\(format.width)x\(format.height)"], "fps_list": [format.fps],
            "bitrate": format.bitrateKbps, "bitrate_now": format.bitrateKbps, "camera": cameraID,
            "cameras": cameras.enumerated().map { ["id": "mac-\($0.offset)", "label": $0.element.name, "front": false] as [String: Any] },
            "front": false, "orient": 0, "audio": false, "torch": false,
            "zoom": 1.0, "zoom_min": 1.0, "zoom_max": 1.0, "has_flash": false,
            "ev": 0.0, "ev_min": 0.0, "ev_max": 0.0,
            "focus": "continuous", "wb": "auto", "antibanding": "auto", "stab": false,
            "battery": -1, "charging": false, "temp": 0, "clients": clients,
            "auth": true, "profile": "", "codec": "h264", "codec_pref": "h264",
            "hevc": false, "abr": false, "lock": false,
            "framing": false, "framing_available": false, "faces": 0,
            "bg": "off", "bg_strength": 0, "bg_image": false,
            "rec": false, "rec_ms": 0, "hot": false, "heat_guard": false,
            "ips": LocalAddresses.ipv4(), "port": 4848,
            "prototype": true, "settings_read_only": true
        ]
    }
}

final class SenderModel: ObservableObject {
    @Published var cameras: [CameraInfo] = []
    @Published var selectedCameraID = ""
    @Published var accessCode = String(format: "%06d", Int.random(in: 0...999999))
    @Published var running = false
    @Published var starting = false
    @Published var clients = 0
    @Published var message = "Ready to share this Mac’s camera."
    @Published var error: String?
    @Published var warning: String?
    @Published var addresses: [String] = []
    @Published var format = CaptureFormat(width: 1920, height: 1080, fps: 30)
    @Published var previewSession: AVCaptureSession?

    private var camera: CameraSource?
    private var server: StreamServer?
    private var runID = UUID()

    func refreshCameras() {
        cameras = CameraSource.availableCameras()
        if !cameras.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = cameras.first?.id ?? ""
        }
        addresses = LocalAddresses.ipv4()
    }

    func start() {
        guard !running, !starting else { return }
        guard accessCode.utf8.count == 6, accessCode.utf8.allSatisfy({ (48...57).contains($0) }) else {
            error = "Choose an access code with exactly six digits."
            return
        }
        error = nil
        warning = nil
        starting = true
        message = "Checking camera permission…"
        let id = UUID()
        runID = id
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            begin(id: id)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.runID == id else { return }
                    if granted { self.begin(id: id) }
                    else { self.fail("Camera access is required. Enable MagerCam Sender in System Settings → Privacy & Security → Camera.", id: id) }
                }
            }
        default:
            fail("Camera access is disabled. Enable MagerCam Sender in System Settings → Privacy & Security → Camera.", id: id)
        }
    }

    private func begin(id: UUID) {
        refreshCameras()
        guard !selectedCameraID.isEmpty else { fail("No camera found. Connect a camera, then click Refresh.", id: id); return }
        let service = StreamServer(port: SenderEnvironment.port, discoveryPort: SenderEnvironment.discoveryPort,
                                   accessCode: accessCode)
        let source = CameraSource(onVideo: { [weak service] video in
            service?.broadcastVideo(configuration: video.configuration, frame: video.data,
                                    pts: video.pts, keyframe: video.keyframe)
        }, onError: { [weak self] detail in
            DispatchQueue.main.async { self?.fail(detail, id: id) }
        })
        server = service
        camera = source
        previewSession = source.session
        let wireCameraID = "mac-\(cameras.firstIndex(where: { $0.id == selectedCameraID }) ?? 0)"
        service.updateStatus(SenderStatus.make(cameras: cameras, cameraID: wireCameraID, format: format))
        service.onKeyframeNeeded = { [weak source] in source?.requestKeyframe() }
        service.onError = { [weak self] detail in
            DispatchQueue.main.async {
                guard let self, self.runID == id else { return }
                if detail.hasPrefix("Discovery is unavailable") { self.warning = detail }
                else { self.fail(detail, id: id) }
            }
        }
        service.onClientCount = { [weak self] count in
            DispatchQueue.main.async {
                guard let self, self.runID == id else { return }
                self.clients = count
            }
        }
        let cameraID = selectedCameraID
        service.onReady = { [weak self, weak source, weak service] in
            // Submit start and stop from the same queue so a late listener-ready
            // callback cannot reopen the camera after the user has stopped sharing.
            DispatchQueue.main.async {
                guard let self, self.runID == id, self.starting, let source else { return }
                source.start(cameraID: cameraID) { [weak self, weak service] result in
                    DispatchQueue.main.async {
                        guard let self, self.runID == id else { return }
                        switch result {
                        case .success(let actual):
                            self.format = actual
                            service?.updateStatus(SenderStatus.make(cameras: self.cameras, cameraID: wireCameraID, format: actual))
                            self.running = true
                            self.starting = false
                            self.message = "Sharing camera. Connect from the other computer."
                        case .failure(let failure): self.fail(failure.localizedDescription, id: id)
                        }
                    }
                }
            }
        }
        do {
            message = "Starting camera and network listener…"
            try service.start()
        } catch { fail(error.localizedDescription, id: id) }
    }

    private func fail(_ detail: String, id: UUID) {
        guard runID == id else { return }
        stop()
        error = detail
        message = "Could not share camera."
    }

    func stop() {
        runID = UUID()
        server?.stop()
        camera?.stop()
        server = nil
        camera = nil
        previewSession = nil
        running = false
        starting = false
        clients = 0
        warning = nil
        message = "Camera stopped."
    }
}

private final class PreviewView: NSView {
    let videoLayer = AVCaptureVideoPreviewLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layout() { super.layout(); videoLayer.frame = bounds }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession?
    func makeNSView(context: Context) -> PreviewView { PreviewView() }
    func updateNSView(_ nsView: PreviewView, context: Context) {
        if nsView.videoLayer.session !== session { nsView.videoLayer.session = session }
    }
}

struct SenderView: View {
    @ObservedObject var model: SenderModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(SenderEnvironment.appName).font(.title2.weight(.semibold))
                    Text("Use this Mac as a camera on another computer.").foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.running ? "Sharing" : "Stopped", systemImage: model.running ? "circle.fill" : "circle")
                    .font(.caption.weight(.medium)).foregroundStyle(model.running ? .green : .secondary)
            }
            ZStack {
                CameraPreview(session: model.previewSession)
                if model.previewSession == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "video").font(.system(size: 36))
                        Text("Camera preview").font(.callout)
                    }.foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(height: 270).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                Picker("Camera", selection: $model.selectedCameraID) {
                    if model.cameras.isEmpty { Text("No camera found").tag("") }
                    ForEach(model.cameras) { camera in Text(camera.name).tag(camera.id) }
                }.disabled(model.running || model.starting)
                Button(action: model.refreshCameras) { Image(systemName: "arrow.clockwise") }
                    .help("Refresh cameras").disabled(model.running || model.starting)
            }
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("MAC IP ADDRESS · PORT " + String(SenderEnvironment.port)).font(.caption).foregroundStyle(.secondary)
                    if model.addresses.isEmpty {
                        Text("Connect to Wi-Fi or Ethernet").font(.callout)
                    } else {
                        ForEach(model.addresses, id: \.self) { address in
                            Text(address).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("ACCESS CODE").font(.caption).foregroundStyle(.secondary)
                    TextField("6 digits", text: $model.accessCode)
                        .font(.system(.body, design: .monospaced)).frame(width: 105)
                        .disabled(model.running || model.starting)
                }
                Spacer(minLength: 0)
            }
            Text("On the receiving computer, open MagerCam, enter this Mac’s IP address and access code, then connect. Both computers must be on the same network.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = model.warning {
                Text(warning).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.message).font(.callout)
                    Text("Video only · \(model.format.width) × \(model.format.height) · \(model.format.fps) fps · \(model.format.bitrateKbps / 1000) Mb/s · \(model.clients) connected")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.running || model.starting ? "Stop sharing" : "Start sharing") {
                    if model.running || model.starting { model.stop() } else { model.start() }
                }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(24).frame(width: 630)
        .onAppear { model.refreshCameras() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = SenderModel()
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 630, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = SenderEnvironment.appName
        window.contentView = NSHostingView(rootView: SenderView(model: model))
        window.minSize = NSSize(width: 630, height: 700)
        window.setContentSize(NSSize(width: 630, height: 740))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        let menu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit \(SenderEnvironment.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        menu.addItem(appMenuItem)
        NSApp.mainMenu = menu
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}
