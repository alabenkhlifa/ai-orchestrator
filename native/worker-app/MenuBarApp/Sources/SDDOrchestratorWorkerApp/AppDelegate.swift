import AppKit
import CoreServices
import SDDOrchestratorWorkerCore

/// Wires `SDDOrchestratorWorkerCore`'s testable decisions to an
/// `NSStatusItem`. Kept thin on purpose — see `Package.swift`'s comment on
/// why the decision logic itself lives in the Core target instead.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var workerBinaryPath = ""
    private var workerProcessController: WorkerProcessController!
    private let commandRunner: CommandRunning = ProcessCommandRunner()

    // Defaults to `.notPaired`/`.unknown` — the safe "offer only Open
    // Dashboard + Quit" state (AC-03) — until the background pairing check
    // in `refreshPairingStatus()` reports back.
    private var pairingStatus: PairingStatus = .notPaired
    private var connectionState: GatewayConnectionState = .unknown
    private var currentStatus: WorkerStatus = .notPaired

    // Polls SddOrchestrator.Worker.ConnectionStatus (see
    // ConnectionStatusQuerier) only once this worker is known to be paired
    // — with no configuration, GatewayConnection never starts, so polling
    // before then would only ever observe `.unknown`.
    private var connectionPollTimer: Timer?
    private let connectionPollInterval: TimeInterval = 5

    // MARK: - URL-scheme pairing handoff (Task 4, AC-07 / AC-08)

    private var pairingFlowController: PairingFlowController?

    // Overrides the disk-based `WorkerStatus.from(pairing:connection:)`
    // derivation once a URL-scheme pairing attempt succeeds this session —
    // `pairingStatus` itself stays disk-derived (see `PairingStatusChecker`)
    // and never becomes `.paired` in this task's scope, so without this
    // override `refreshStatus()` could never show "Paired, setting up…".
    private var urlPairingOverrideStatus: WorkerStatus?

    // The most recent URL-scheme pairing failure's reason, shown as an
    // extra disabled menu line under "Not paired" (AC-08). Cleared once a
    // new attempt starts or succeeds.
    private var pairingFailureDetail: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Registered before anything else: a GetURL Apple Event sent at
        // launch time (the user opened a sddworker:// link and that launched
        // this app) can arrive before this method returns, and AppKit only
        // redelivers it once a handler is registered — see
        // `registerURLSchemeHandler()`'s own doc comment.
        registerURLSchemeHandler()

        setUpStatusItem()
        rebuildMenu()

        guard let resourcePath = Bundle.main.resourcePath else {
            logError("no bundle resourcePath; cannot locate the embedded release")
            return
        }

        workerBinaryPath = WorkerPaths.workerBinaryPath(resourcePath: resourcePath)
        workerProcessController = WorkerProcessController(workerBinaryPath: workerBinaryPath)
        workerProcessController.onUnexpectedExit = { [weak self] status in
            DispatchQueue.main.async {
                self?.logError("embedded worker process exited unexpectedly (status \(status))")
                self?.connectionState = .disconnected
                self?.refreshStatus()
            }
        }

        do {
            try workerProcessController.start()
        } catch {
            logError("failed to start the embedded release: \(error)")
        }

        setUpPairingFlowController()
        refreshPairingStatus()
    }

    // MARK: - Status item / menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "SDD Orchestrator Worker")
            image?.isTemplate = true
            button.image = image
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let statusLineItem = NSMenuItem(title: currentStatus.menuStatusLine, action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)

        // [AC-08] The specific reason the last URL-scheme pairing attempt
        // failed, surfaced as its own disabled line rather than folded into
        // `currentStatus.menuStatusLine` — keeps `WorkerStatus` a small,
        // fixed set of display strings while still reporting the real
        // reason (never the raw pairing code or credential) in the menu.
        if currentStatus == .notPaired, let pairingFailureDetail {
            let detailItem = NSMenuItem(
                title: "Pairing failed: \(pairingFailureDetail)",
                action: nil,
                keyEquivalent: ""
            )
            detailItem.isEnabled = false
            menu.addItem(detailItem)
        }

        menu.addItem(.separator())

        // AC-03: not-paired offers only these two items — no manual
        // pairing-code entry field or any other action. Tasks 4/9 add
        // status-specific items later; nothing else exists to add yet, so
        // every status currently shares this same two-item menu.
        let openDashboardItem = NSMenuItem(
            title: "Open Dashboard",
            action: #selector(openDashboard(_:)),
            keyEquivalent: ""
        )
        openDashboardItem.target = self
        menu.addItem(openDashboardItem)

        // `target: nil` + the standard `terminate:` selector resolves
        // through the responder chain to `NSApp`, which routes it to
        // `applicationShouldTerminate(_:)` below — the single place the
        // AC-04/AC-05 confirmation decision is made, regardless of what
        // triggers termination.
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func refreshStatus() {
        currentStatus = urlPairingOverrideStatus ?? WorkerStatus.from(pairing: pairingStatus, connection: connectionState)
        rebuildMenu()
    }

    // MARK: - Pairing status (AC-03)

    private func refreshPairingStatus() {
        let binaryPath = workerBinaryPath
        let runner = commandRunner

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pairing = PairingStatusChecker.check(workerBinaryPath: binaryPath, runner: runner)

            DispatchQueue.main.async {
                guard let self else { return }
                self.pairingStatus = pairing
                self.refreshStatus()

                if pairing == .paired {
                    self.startConnectionPolling()
                }
            }
        }
    }

    // MARK: - URL-scheme pairing handoff (Task 4, AC-07 / AC-08)

    /// Registers an Apple Event handler for `kInternetEventClass`/
    /// `kAEGetURL` — the correct AppKit mechanism for receiving a custom
    /// URL-scheme open (`sddworker://...`). There is no
    /// `application(_:open:)` on macOS; that is UIKit. LaunchServices
    /// delivers a registered custom URL scheme as this Apple Event instead,
    /// and if this app was launched *by* opening the link, AppKit holds the
    /// event and redelivers it once a handler is registered here — which is
    /// why this call happens first in `applicationDidFinishLaunching`.
    private func registerURLSchemeHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue
        pairingFlowController?.handle(urlString: urlString)
    }

    private func setUpPairingFlowController() {
        let dashboardURL = DashboardURLProvider.dashboardURL(infoDictionary: Bundle.main.infoDictionary)
        let binaryPath = workerBinaryPath
        let runner = commandRunner

        pairingFlowController = PairingFlowController(
            dashboardURL: dashboardURL,
            selfReportProvider: {
                WorkerSelfReport(
                    osFamily: "macos",
                    osMajor: String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
                    protocolVersion: ProtocolVersionQuerier.query(workerBinaryPath: binaryPath, runner: runner),
                    appVersion: WorkerAppVersionReader.appVersion(infoDictionary: Bundle.main.infoDictionary)
                )
            },
            httpPoster: URLSessionPairingHTTPPoster(),
            setupCoordinator: PostPairingSetupCoordinatorImpl(
                dashboardURL: dashboardURL,
                workerBinaryPath: binaryPath,
                commandRunner: runner,
                folderPicker: NSOpenPanelWorkspaceFolderPicker(),
                agentSelectionPrompt: AgentSelectionAlertPrompt()
            ),
            onStateChange: { [weak self] state in
                DispatchQueue.main.async {
                    self?.handlePairingFlowStateChange(state)
                }
            }
        )
    }

    private func handlePairingFlowStateChange(_ state: PairingFlowController.State) {
        switch state {
        case .inFlight:
            pairingFailureDetail = nil
            rebuildMenu()

        case .succeeded:
            pairingFailureDetail = nil
            urlPairingOverrideStatus = .pairedSettingUp
            refreshStatus()

        case .failed(let detail):
            pairingFailureDetail = detail
            refreshStatus()
        }
    }

    // MARK: - Connection status polling (plumbing for Tasks 9/10)

    private func startConnectionPolling() {
        guard connectionPollTimer == nil else { return }

        let timer = Timer(timeInterval: connectionPollInterval, repeats: true) { [weak self] _ in
            self?.pollConnectionStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        connectionPollTimer = timer

        pollConnectionStatus()
    }

    private func pollConnectionStatus() {
        let binaryPath = workerBinaryPath
        let runner = commandRunner

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let state = ConnectionStatusQuerier.query(workerBinaryPath: binaryPath, runner: runner)

            DispatchQueue.main.async {
                self?.connectionState = state
                self?.refreshStatus()
            }
        }
    }

    // MARK: - Open Dashboard

    @objc private func openDashboard(_ sender: Any?) {
        let url = DashboardURLProvider.dashboardURL(infoDictionary: Bundle.main.infoDictionary)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Quit (AC-04 / AC-05)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workerProcessController, workerProcessController.isRunning else {
            return .terminateNow
        }

        let binaryPath = workerBinaryPath
        let runner = commandRunner

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let queryResult = RunStateQuerier.query(workerBinaryPath: binaryPath, runner: runner)
            let shouldWarn = ActiveRunChecker.shouldWarnBeforeQuit(queryResult: queryResult)

            DispatchQueue.main.async {
                guard let self else { return }

                if shouldWarn {
                    if self.confirmQuitWithActiveRun() {
                        self.stopEmbeddedWorkerAndReply()
                    } else {
                        NSApp.reply(toApplicationShouldTerminate: false)
                    }
                } else {
                    self.stopEmbeddedWorkerAndReply()
                }
            }
        }

        return .terminateLater
    }

    /// [AC-05] "A run is in progress. Quitting will stop it. Quit anyway?"
    private func confirmQuitWithActiveRun() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "A run is in progress."
        alert.informativeText = "Quitting will stop it. Quit anyway?"
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    /// [AC-04] Stops the embedded worker process, then finishes
    /// termination. Never touches `Configuration`'s storage (see
    /// `WorkerProcessController.stop(timeout:)`, which only signals the
    /// running process and shells out to `bin/worker rpc`/`terminate`/
    /// `SIGKILL` — no file under the worker's home directory is written or
    /// deleted by this path).
    private func stopEmbeddedWorkerAndReply() {
        let controller = workerProcessController

        DispatchQueue.global(qos: .userInitiated).async {
            controller?.stop()

            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
    }

    private func logError(_ message: String) {
        FileHandle.standardError.write(Data("SDD Orchestrator Worker: \(message)\n".utf8))
    }
}
