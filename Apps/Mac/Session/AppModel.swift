import AppKit
import Observation
import VRProtocol

/// The Mac app's state and the conductor of a session: it decides which displays exist, what is
/// captured, what the phone is told to draw, and what the physical screens show meanwhile.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase: Equatable {
        case idle, starting, running, stopping
    }

    var settings: AppSettings {
        didSet { settingsDidChange(from: oldValue) }
    }

    /// True from the moment a session is asked for until it is asked to stop.
    private(set) var isActive = false
    private(set) var phase: Phase = .idle
    /// Why the last session ended or could not start, if it was not the user's doing.
    private(set) var lastError: String?
    private(set) var peer: Peer?
    private(set) var phoneStatus: ClientStatus?
    private(set) var displays: [DisplayInfo] = []
    private(set) var stats: [StreamStats] = []
    /// Stream of the screen that sits straight ahead after recentering.
    private(set) var focusedStream: UInt16 = 0
    private(set) var isScreenRevealed = false
    private(set) var isCinema = false
    private(set) var hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()

    @ObservationIgnored let hotkeys = HotkeyCenter()
    @ObservationIgnored private let endpoint: HostEndpoint
    @ObservationIgnored private let streams: StreamSession
    @ObservationIgnored private let virtualDisplays = VirtualDisplayManager()
    @ObservationIgnored private let privacy = PrivacyScreen()
    @ObservationIgnored private let resolutionSwitcher = SessionResolutionSwitcher()

    @ObservationIgnored private var operations: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var disconnectGrace: Task<Void, Never>?
    @ObservationIgnored private var sentScene: SceneState?
    @ObservationIgnored private var sentAssetID: String?
    @ObservationIgnored private var environmentAsset: AssetMessage?
    private var cinemaAngle = SceneState.cinemaScreenAngle

    /// Most virtual monitors the app will add.
    static let maxVirtualMonitors = 4
    /// Viewer resolution assumed until the phone reports its own.
    private static let fallbackPixelsPerDegree = 15.0

    private init() {
        settings = AppSettings.load()
        let endpoint = HostEndpoint(hostName: Host.current().localizedName ?? "Mac")
        self.endpoint = endpoint
        streams = StreamSession { frame in endpoint.send(frame) }
    }

    // MARK: - Launch and exit

    func launch() {
        // Repairs the display if a previous run ended while the backlight was off.
        Backlight.restore()
        refreshDisplays()
        loadEnvironmentImage()

        hotkeys.onAction = { [weak self] action in self?.perform(action) }
        registerHotkeys()

        endpoint.setVideoHandler { [streams] frame in streams.handle(frame) }
        endpoint.start(preference: settings.general.connection) { [weak self] event in
            // Dispatch rather than a task: events must arrive in order.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysDidChange() }
        }

        Task { [weak self] in
            guard let failures = self?.streams.failures else { return }
            for await failure in failures {
                self?.streamDidFail(failure)
            }
        }
        Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                count += 1
                self?.tick(count)
            }
        }
    }

    /// Puts the Mac back the way it was, synchronously, for use while the app is exiting.
    func restoreMac() {
        privacy.clear()
        virtualDisplays.removeAll()
        resolutionSwitcher.restore()
        isScreenRevealed = false
        isCinema = false
        focusedStream = 0
    }

    // MARK: - Session lifecycle

    func startSession() {
        guard !isActive else { return }
        guard peer != nil else {
            lastError = "Open LaptopVR on your iPhone and connect it with a cable or the same Wi-Fi network."
            return
        }
        if !CGPreflightScreenCaptureAccess() {
            // Shows the system prompt the first time; capture fails below if it is declined.
            CGRequestScreenCaptureAccess()
        }
        lastError = nil
        isActive = true
        enqueue { await $0.bringUp() }
    }

    func stopSession() {
        guard isActive else { return }
        isActive = false
        refreshTask?.cancel()
        enqueue { await $0.tearDown() }
    }

    func toggleSession() {
        isActive ? stopSession() : startSession()
    }

    /// Runs session operations one after another, so a stop never overlaps a start.
    private func enqueue(_ operation: @escaping @MainActor (AppModel) async -> Void) {
        let previous = operations
        operations = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await operation(self)
        }
    }

    private func bringUp() async {
        guard isActive, phase == .idle else { return }
        phase = .starting
        do {
            try await configure()
            phase = .running
            registerHotkeys()
            pushScene()
        } catch {
            await fail(error)
        }
    }

    private func reconfigure() async {
        // Without a phone there is nothing to size the streams for; wait for it to return.
        guard isActive, phase == .running, peer != nil else { return }
        do {
            try await configure()
            pushScene()
        } catch {
            await fail(error)
        }
    }

    private func tearDown() async {
        guard phase != .idle else { return }
        phase = .stopping
        pushScene()
        await streams.stopAll()
        restoreMac()
        stats = []
        phase = .idle
        registerHotkeys()
        refreshDisplays()
    }

    private func fail(_ error: any Error) async {
        isActive = false
        await tearDown()
        refreshPermission()
        lastError = hasScreenRecordingPermission
            ? error.localizedDescription
            : "LaptopVR needs Screen Recording permission. Allow it in System Settings, then start again."
    }

    /// Brings displays, privacy, and streams in line with the settings. Safe to repeat: every
    /// step does nothing when it is already in the wanted state.
    private func configure() async throws {
        let monitors = settings.displays.multiMonitor ? settings.displays.virtualMonitors : []

        // A stream must stop before its display goes away, or it reports a failure.
        let stale = virtualDisplays.staleSerials(for: monitors)
        await streams.stop(stale.map { UInt16(truncatingIfNeeded: $0) })

        resolutionSwitcher.apply(settings.displays.sessionResolution, to: CGMainDisplayID())
        if virtualDisplays.sync(with: monitors) {
            await virtualDisplays.waitUntilSettled()
        }
        refreshDisplays()

        privacy.apply(
            mode: isScreenRevealed ? .off : settings.privacy.mode,
            appearance: PrivacyScreen.Appearance(
                style: settings.privacy.coverStyle,
                imagePath: settings.privacy.coverImagePath,
                revealHint: settings.shortcuts[.revealScreen]?.label ?? ""
            ),
            displays: displays
        )

        try await streams.apply(streamConfigurations())
    }

    // MARK: - What is shown

    /// Displays that appear in the headset, main display first.
    var shownDisplays: [DisplayInfo] {
        let showsExtras = settings.displays.multiMonitor && !isCinema
        let shown = displays.filter { display in
            display.isMain || (showsExtras && (display.isVirtual || settings.displays.includeExternalDisplays))
        }
        return Array(shown.prefix(LaptopVRProtocol.maxScreens))
    }

    /// Angular width of the main screen: the zoom. Cinema view has its own, so leaving it
    /// returns to the zoom you had.
    var zoomAngle: Double {
        get { isCinema ? cinemaAngle : settings.view.screenAngle }
        set {
            let angle = min(max(newValue, SceneState.screenAngleRange.lowerBound), SceneState.screenAngleRange.upperBound)
            if isCinema {
                cinemaAngle = angle
                pushScene()
                scheduleRefresh()
            } else {
                settings.view.screenAngle = angle
            }
        }
    }

    /// The chosen codec, or H.264 if the phone cannot decode it.
    var activeCodec: VideoCodec {
        settings.quality.codec == .hevc && peer?.supportsHEVC == true ? .hevc : .h264
    }

    private func streamConfigurations() -> [StreamConfiguration] {
        let shown = shownDisplays
        let mainWidth = shown.first(where: \.isMain)?.bounds.width ?? 1
        let codec = activeCodec
        let frameRateLimit = min(settings.quality.framesPerSecond, peer?.maxFramesPerSecond ?? 60)
        let excluded = privacy.coverWindowIDs

        return shown.map { display in
            let size = StreamSizing.size(
                for: display,
                angularWidthDegrees: zoomAngle * display.bounds.width / mainWidth,
                pixelsPerDegree: phoneStatus?.pixelsPerDegree ?? Self.fallbackPixelsPerDegree,
                preference: settings.quality.resolution,
                codec: codec
            )
            return StreamConfiguration(
                streamID: display.streamID,
                displayID: display.id,
                width: size.width,
                height: size.height,
                codec: codec,
                bitsPerSecond: Int(settings.quality.megabitsPerSecond * 1_000_000),
                framesPerSecond: StreamSizing.framesPerSecond(
                    for: display, size: size, codec: codec, limit: frameRateLimit),
                excludedWindowIDs: excluded
            )
        }
    }

    private func makeScene() -> SceneState {
        let shown = phase == .running ? shownDisplays : []
        let screens = SceneBuilder.screens(for: shown)

        var environment = settings.surroundings.environment
        environment.imageAssetID = environment.kind == .image ? environmentAsset?.id : nil
        var distance = settings.view.distance
        if isCinema {
            // A dark room with the screen further away, like a theatre.
            if environment.kind != .passthrough {
                environment.kind = .solid
                environment.primaryColor = .black
            }
            distance = max(distance, 3)
        }

        return SceneState(
            sessionActive: phase == .running,
            screens: screens,
            focusedScreen: screens.contains { $0.id == focusedStream } ? focusedStream : 0,
            mode: settings.view.mode,
            screenAngleDegrees: zoomAngle,
            distanceMeters: distance,
            curvature: SceneBuilder.curvature(for: settings.view.curve, screenCount: screens.count),
            environment: environment,
            showStats: settings.view.showStats
        )
    }

    /// Sends the scene to the phone if it differs from what the phone already has.
    private func pushScene() {
        guard peer != nil else { return }
        let scene = makeScene()
        if let asset = environmentAsset, scene.environment.imageAssetID == asset.id, sentAssetID != asset.id {
            endpoint.send(asset.frame())
            sentAssetID = asset.id
        }
        guard scene != sentScene else { return }
        endpoint.send(.json(.scene, scene))
        sentScene = scene
    }

    private func loadEnvironmentImage() {
        guard let path = settings.surroundings.imagePath else {
            environmentAsset = nil
            return
        }
        Task { [weak self] in
            let asset = await Task.detached(priority: .utility) {
                ImageStore.environmentAsset(atPath: path)
            }.value
            guard let self, self.settings.surroundings.imagePath == path else { return }
            self.environmentAsset = asset
            self.pushScene()
        }
    }

    // MARK: - Reacting to changes

    private func settingsDidChange(from old: AppSettings) {
        guard settings != old else { return }
        settings.save()

        if settings.shortcuts != old.shortcuts {
            registerHotkeys()
        }
        if settings.general.connection != old.general.connection {
            endpoint.setPreference(settings.general.connection)
        }
        if settings.surroundings.imagePath != old.surroundings.imagePath {
            loadEnvironmentImage()
        }
        // The scene goes out at once so zooming feels immediate; displays and streams follow.
        pushScene()
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard phase == .running else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.enqueue { await $0.reconfigure() }
        }
    }

    private func handle(_ event: HostEndpoint.Event) {
        switch event {
        case .connected(let peer):
            self.peer = peer
            disconnectGrace?.cancel()
            // A new link starts with an empty decoder and has seen neither scene nor image.
            streams.resetForNewLink()
            sentScene = nil
            sentAssetID = nil
            pushScene()
            scheduleRefresh()

        case .disconnected:
            peer = nil
            // A re-seated cable or a Wi-Fi hiccup should not end the session.
            disconnectGrace?.cancel()
            disconnectGrace = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let self, self.peer == nil else { return }
                self.phoneStatus = nil
                self.stopSession()
            }

        case .status(let status):
            let previous = phoneStatus
            phoneStatus = status
            if settings.general.startsWithHeadset, status.headsetActive != (previous?.headsetActive ?? false) {
                status.headsetActive ? startSession() : stopSession()
            }
            if status.pixelsPerDegree != previous?.pixelsPerDegree {
                scheduleRefresh()
            }
        }
    }

    private func displaysDidChange() {
        refreshDisplays()
        scheduleRefresh()
    }

    private func refreshDisplays() {
        let current = DisplayCatalog.current()
        if current != displays {
            displays = current
        }
    }

    private func streamDidFail(_ failure: StreamSession.Failure) {
        enqueue { model in
            guard model.phase == .running else { return }
            await model.streams.stop([failure.streamID])
            if DisplayCatalog.current().contains(where: { $0.streamID == failure.streamID }) {
                // The display is still there, so capture itself was stopped or broke.
                await model.fail(StreamFailure(message: failure.message))
            } else {
                await model.reconfigure()
            }
        }
    }

    private struct StreamFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func tick(_ count: Int) {
        guard phase == .running else { return }
        if settings.view.centerFollowsCursor {
            focusDisplayUnderCursor()
        }
        if count.isMultiple(of: 4), let peer {
            stats = streams.takeStats()
            if settings.view.showStats {
                let host = HostStats(codec: activeCodec.displayName, transport: peer.transport.title, streams: stats)
                endpoint.send(.json(.stats, host))
            }
        }
    }

    private func focusDisplayUnderCursor() {
        // AppKit measures from the bottom of the primary screen, Core Graphics from its top.
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let location = NSEvent.mouseLocation
        let point = CGPoint(x: location.x, y: primaryHeight - location.y)
        guard let display = shownDisplays.first(where: { $0.bounds.contains(point) }),
              display.streamID != focusedStream
        else { return }
        focusedStream = display.streamID
        pushScene()
    }

    // MARK: - Permission

    func refreshPermission() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecordingPermission() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        refreshPermission()
    }

    // MARK: - Actions

    func perform(_ action: HotkeyAction) {
        switch action {
        case .toggleSession: toggleSession()
        case .recenter: recenter()
        case .zoomIn: zoom(by: 1.12)
        case .zoomOut: zoom(by: 1 / 1.12)
        case .toggleMode: toggleMode()
        case .togglePassthrough: togglePassthrough()
        case .revealScreen: toggleReveal()
        case .cinema: toggleCinema()
        case .nextDisplay: focusDisplay(offset: 1)
        case .previousDisplay: focusDisplay(offset: -1)
        case .addMonitor: addVirtualMonitor()
        case .removeMonitor: removeVirtualMonitor()
        case .toggleStats: settings.view.showStats.toggle()
        }
    }

    func recenter() {
        endpoint.send(.json(.command, HostCommand.recenter))
    }

    func zoom(by factor: Double) {
        zoomAngle *= factor
        toast("Screen width \(Int(zoomAngle.rounded()))°")
    }

    func toggleMode() {
        settings.view.mode = settings.view.mode == .anchored ? .follow : .anchored
        toast(settings.view.mode == .anchored ? "Anchored" : "Follow")
    }

    func togglePassthrough() {
        var surroundings = settings.surroundings
        if surroundings.environment.kind == .passthrough {
            surroundings.environment.kind = surroundings.kindBeforePassthrough
        } else {
            surroundings.kindBeforePassthrough = surroundings.environment.kind
            surroundings.environment.kind = .passthrough
        }
        settings.surroundings = surroundings
        toast(surroundings.environment.kind == .passthrough ? "Passthrough on" : "Passthrough off")
    }

    /// Shows the desktop on the Mac's own screen again, or hides it, without ending the session.
    func toggleReveal() {
        guard phase == .running else { return }
        isScreenRevealed.toggle()
        scheduleRefresh()
    }

    /// Main screen only, smaller and further away in a dark room, for watching video.
    func toggleCinema() {
        guard phase == .running else { return }
        isCinema.toggle()
        pushScene()
        scheduleRefresh()
        toast(isCinema ? "Cinema view" : "Desk view")
    }

    func focus(stream: UInt16) {
        focusedStream = stream
        pushScene()
    }

    private func focusDisplay(offset: Int) {
        let ordered = shownDisplays.sorted { $0.bounds.minX < $1.bounds.minX }
        guard ordered.count > 1 else { return }
        let current = ordered.firstIndex { $0.streamID == focusedStream } ?? ordered.firstIndex(where: \.isMain) ?? 0
        let next = ordered[(current + offset + ordered.count) % ordered.count]
        focus(stream: next.streamID)
        toast(next.name)
    }

    func addVirtualMonitor() {
        var displays = settings.displays
        if displays.multiMonitor || displays.virtualMonitors.isEmpty {
            guard displays.virtualMonitors.count < Self.maxVirtualMonitors else {
                toast("No more monitors can be added")
                return
            }
            let used = Set(displays.virtualMonitors.map(\.id))
            let identifier = (1...UInt32(Self.maxVirtualMonitors)).first { !used.contains($0) } ?? 1
            let template = displays.virtualMonitors.last
            displays.virtualMonitors.append(VirtualMonitorSpec(
                id: identifier,
                width: template?.width ?? 1440,
                height: template?.height ?? 900,
                hiDPI: template?.hiDPI ?? true
            ))
        }
        displays.multiMonitor = true
        settings.displays = displays
        toast(displays.virtualMonitors.count == 1 ? "1 extra monitor" : "\(displays.virtualMonitors.count) extra monitors")
    }

    func removeVirtualMonitor() {
        var displays = settings.displays
        guard displays.multiMonitor else { return }
        if displays.virtualMonitors.count > 1 {
            displays.virtualMonitors.removeLast()
            toast(displays.virtualMonitors.count == 1 ? "1 extra monitor" : "\(displays.virtualMonitors.count) extra monitors")
        } else {
            // The last one stays configured, so adding a monitor later brings it back.
            displays.multiMonitor = false
            toast("Extra monitors off")
        }
        settings.displays = displays
    }

    func moveDisplay(_ display: CGDirectDisplayID, to origin: CGPoint) {
        DisplayCatalog.move(display, to: origin)
        displaysDidChange()
    }

    func setSurroundingsImage(from url: URL) {
        guard let path = ImageStore.importImage(from: url, replacing: settings.surroundings.imagePath) else { return }
        var surroundings = settings.surroundings
        surroundings.imagePath = path
        surroundings.environment.kind = .image
        settings.surroundings = surroundings
    }

    func setCoverImage(from url: URL) {
        guard let path = ImageStore.importImage(from: url, replacing: settings.privacy.coverImagePath) else { return }
        var privacy = settings.privacy
        privacy.coverImagePath = path
        privacy.coverStyle = .image
        settings.privacy = privacy
    }

    /// Shows a short message in the headset.
    private func toast(_ text: String) {
        guard phase == .running else { return }
        endpoint.send(.json(.command, HostCommand.toast(text)))
    }

    /// Only the start shortcut is claimed while idle, so the rest stay free for other apps.
    private func registerHotkeys() {
        let active = phase == .running
        hotkeys.register(settings.shortcuts.filter { active || $0.key == .toggleSession })
    }
}
