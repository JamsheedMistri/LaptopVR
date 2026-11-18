import Observation
import UIKit
import VideoToolbox
import VRProtocol

/// The iPhone app's state: the connection to the Mac, the scene it asked for, and whether the
/// headset view is up.
@MainActor
@Observable
final class AppModel {
    enum HostLink: Equatable {
        case searching
        case connected(host: String, transport: String)
    }

    private(set) var link = HostLink.searching
    /// Why the phone cannot accept connections, if it cannot.
    private(set) var listenerError: String?
    private(set) var scene = SceneState()
    /// Why the headset view cannot be drawn, if it cannot.
    private(set) var rendererError: String?

    var isInHeadset = false {
        didSet {
            if isInHeadset != oldValue { headsetDidChange() }
        }
    }

    var profile: ViewerProfile {
        didSet {
            guard profile != oldValue else { return }
            renderer?.setProfile(profile)
            if let data = try? JSONEncoder().encode(profile) {
                UserDefaults.standard.set(data, forKey: Keys.profile)
            }
            sendStatus()
        }
    }

    /// Enter the headset view by itself when the Mac starts a session.
    var entersAutomatically: Bool {
        didSet { UserDefaults.standard.set(entersAutomatically, forKey: Keys.entersAutomatically) }
    }

    @ObservationIgnored let renderer: StereoRenderer?
    @ObservationIgnored private let frames = FrameStore()
    @ObservationIgnored private let tracker = HeadTracker()
    @ObservationIgnored private let passthrough: Passthrough
    @ObservationIgnored private let connection: HostConnection
    @ObservationIgnored private var hostStats: HostStats?
    @ObservationIgnored private var warnedAboutHeat = false

    private enum Keys {
        static let profile = "viewerProfile"
        static let entersAutomatically = "entersAutomatically"
    }

    init() {
        let defaults = UserDefaults.standard
        profile = defaults.data(forKey: Keys.profile)
            .flatMap { try? JSONDecoder().decode(ViewerProfile.self, from: $0) } ?? .cardboardV2
        entersAutomatically = defaults.object(forKey: Keys.entersAutomatically) as? Bool ?? true

        let passthrough = Passthrough(tracker: tracker)
        self.passthrough = passthrough
        do {
            renderer = try StereoRenderer(frames: frames, tracker: tracker, passthrough: passthrough)
        } catch {
            renderer = nil
            rendererError = error.localizedDescription
        }

        connection = HostConnection(frames: frames, deviceName: UIDevice.current.name)
    }

    /// Call once the app has a window: the screen's refresh rate is not known before that.
    func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        renderer?.setProfile(profile)
        updateMessage()

        let hello = ClientHello(
            deviceName: UIDevice.current.name,
            supportsHEVC: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
            maxFramesPerSecond: DisplayMetrics.currentScreen?.maximumFramesPerSecond ?? 60
        )
        connection.start(hello: hello) { [weak self] event in
            // Dispatch rather than a task: events must arrive in order.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }

        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.everySecond()
            }
        }
    }

    /// Call when the app goes to the background.
    func suspend() {
        connection.suspendListening()
    }

    /// Call when the app becomes active. Does nothing unless `suspend` came before it.
    func resume() {
        connection.resumeListening()
    }

    func recenter() {
        renderer?.recenter()
    }

    // MARK: - Events from the Mac

    private func handle(_ event: HostConnection.Event) {
        switch event {
        case .listening(let error):
            listenerError = error

        case .connected(let host):
            link = .connected(host: host.hostName, transport: host.transport == "usb" ? "USB" : "Wi-Fi")
            updateMessage()
            sendStatus()

        case .disconnected:
            link = .searching
            hostStats = nil
            apply(SceneState())

        case .scene(let scene):
            let sessionStarted = scene.sessionActive && !self.scene.sessionActive
            apply(scene)
            if sessionStarted, entersAutomatically {
                isInHeadset = true
            }

        case .command(.recenter):
            renderer?.recenter()

        case .command(.toast(let text)):
            renderer?.showToast(text)

        case .stats(let stats):
            hostStats = stats
            updateStatsLines()

        case .asset(let asset):
            renderer?.setSurroundingsImage(id: asset.id, data: asset.data)
        }
    }

    private func apply(_ scene: SceneState) {
        self.scene = scene
        renderer?.setScene(scene)
        frames.keepOnly(Set(scene.screens.map(\.id)))
        updatePassthrough()
        updateMessage()
    }

    // MARK: - Headset

    private func headsetDidChange() {
        if isInHeadset {
            tracker.start()
        } else {
            tracker.stop()
        }
        UIApplication.shared.isIdleTimerDisabled = isInHeadset
        updatePassthrough()

        // The headset view is landscape; everything else is portrait.
        OrientationLock.mask = isInHeadset ? .landscape : .portrait
        for case let windowScene as UIWindowScene in UIApplication.shared.connectedScenes {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: OrientationLock.mask))
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
        // The Mac may be waiting for this to start or stop the session.
        sendStatus()
    }

    /// The camera runs only while it is being looked through.
    private func updatePassthrough() {
        if isInHeadset, scene.sessionActive, scene.environment.kind == .passthrough {
            passthrough.start()
        } else {
            passthrough.stop()
        }
    }

    private func updateMessage() {
        let message: HUDContent? = switch link {
        case .searching:
            HUDContent(title: "Waiting for your Mac", detail: "Open LaptopVR on your Mac and plug in this iPhone")
        case .connected(let host, _) where !scene.sessionActive:
            HUDContent(title: "Connected", detail: "Start LaptopVR from the menu bar on \(host)")
        case .connected:
            nil
        }
        renderer?.setMessage(message)
    }

    // MARK: - Reporting to the Mac

    private func everySecond() {
        sendStatus()
        if scene.showStats {
            updateStatsLines()
        }

        let isHot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if isHot, !warnedAboutHeat, isInHeadset {
            renderer?.showToast("iPhone is getting hot")
        }
        warnedAboutHeat = isHot
    }

    private func sendStatus() {
        let device = UIDevice.current
        let metrics = renderer?.metrics ?? StereoRenderer.Metrics()
        let pixelsPerMeter = DisplayMetrics.currentScreen.map(DisplayMetrics.pixelsPerMeter(of:)) ?? 18_110

        let status = ClientStatus(
            batteryLevel: device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil,
            isCharging: device.batteryState == .charging || device.batteryState == .full,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            headsetActive: isInHeadset,
            positionalTracking: passthrough.latestFrame?.position != nil,
            pixelsPerDegree: Double(profile.pixelsPerDegree(pixelsPerMeter: pixelsPerMeter)),
            renderFramesPerSecond: metrics.framesPerSecond,
            decodeMillis: connection.averageDecodeMillis,
            presentMillis: metrics.presentMillis
        )
        connection.send(.json(.status, status))
    }

    private func updateStatsLines() {
        var lines: [String] = []
        if let hostStats {
            lines.append("\(hostStats.codec) over \(hostStats.transport)")
            for stream in hostStats.streams {
                lines.append(String(
                    format: "%d×%d   %.0f fps   %.1f Mbps   %.0f ms",
                    stream.width, stream.height, stream.framesPerSecond, stream.megabitsPerSecond, stream.pipelineMillis
                ))
            }
        }
        let metrics = renderer?.metrics ?? StereoRenderer.Metrics()
        lines.append(String(
            format: "iPhone   %.0f fps   decode %.1f ms   display %.0f ms",
            metrics.framesPerSecond, connection.averageDecodeMillis, metrics.presentMillis
        ))
        renderer?.setStatsLines(lines)
    }
}

/// Which orientations the app allows right now. UIKit asks the app delegate.
@MainActor
enum OrientationLock {
    static var mask = UIInterfaceOrientationMask.portrait
}
