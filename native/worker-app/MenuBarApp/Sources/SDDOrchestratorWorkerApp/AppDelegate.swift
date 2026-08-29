import AppKit
import CoreServices
import SDDOrchestratorWorkerCore

/// Wires `SDDOrchestratorWorkerCore`'s testable decisions to an
/// `NSStatusItem`. Kept thin on purpose — see `Package.swift`'s comment on
/// why the decision logic itself lives in the Core target instead.
/// The real clipboard, behind `SDDOrchestratorWorkerCore`'s seam so the copy
/// decision itself stays testable without AppKit.
private final class SystemPasteboard: Pasteboarding {
    func write(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

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

    // [specs/38] While unpaired the app holds a code of its own so the person
    // has something to copy. It is dropped the moment pairing succeeds.
    private var pairingCodeHolder: PairingCodeHolder?
    private var pairingCodeCopier: PairingCodeCopier?
    private var pairingCodeJustCopied = false

    // [specs/39 Task 2, AC-01] Keeps the credential and worker identity a
    // redemption issues, instead of specs/38's discard. See
    // `setUpPairingCode()` for the wiring and `MacPairingRetention` for why
    // the only durable copy is the release's own `worker.json`.
    private var macPairingRetention: MacPairingRetention?

    // The loop that actually closes the round trip. Without it the app fetched
    // one code at startup, never replaced it, and never tried to finish, so a
    // code the person pasted was never acted on.
    private var pairingLoopTimer: Timer?
    private let pairingLoopInterval: TimeInterval = 5
    private var pairingCompletionInFlight = false
    private let pairingCompletionPoster: PairingHTTPPosting = URLSessionPairingHTTPPoster()

    // Polls SddOrchestrator.Worker.ConnectionStatus (see
    // ConnectionStatusQuerier) only once this worker is known to be paired
    // — with no configuration, GatewayConnection never starts, so polling
    // before then would only ever observe `.unknown`.
    private var connectionPollTimer: Timer?
    private let connectionPollInterval: TimeInterval = 5

    // MARK: - Periodic signed-appcast check (Task 10, AC-11 / AC-12)

    private var appcastUpdateChecker: AppcastUpdateChecker?
    private var appcastCheckTimer: Timer?
    private let appcastCheckInterval: TimeInterval = AppcastUpdateChecker.defaultInterval

    // Set once AppcastUpdateChecker has verified a newer signed appcast
    // entry, downloaded its artifact, and confirmed the artifact's
    // checksum — see setUpAppcastUpdateChecker(). Overrides
    // WorkerStatus.from(pairing:connection:) in refreshStatus() exactly like
    // urlPairingOverrideStatus does, and is never cleared once set this
    // session (Task 11 owns what happens after the user acts on it).
    private var pendingUpdate: PendingUpdateArtifact?

    // MARK: - Confirmed update install (Task 11, AC-13 / AC-14)

    private var updateInstallCoordinator: UpdateInstallCoordinator?

    // Set once `updateInstallCoordinator` hands off to the install helper
    // and this app calls `NSApp.terminate(nil)` on itself -- checked at the
    // top of `applicationShouldTerminate(_:)` so that termination skips the
    // AC-05 "a run is in progress" warning: the active-run gate was already
    // satisfied (immediately, or by waiting for a deferred run to finish)
    // before the coordinator ever handed off to the installer, so re-asking
    // here would be redundant, not safer.
    private var isInstallingUpdate = false

    // [AC-14] Re-checks run state on a short interval while an install is
    // deferred (`UpdateInstallCoordinator.State.awaitingActiveRunToFinish`)
    // -- a dedicated timer rather than piggybacking on
    // `connectionPollTimer` (semantically unrelated: that one polls gateway
    // connectivity and runs continuously once paired, this one only runs
    // while an install is actually pending and stops as soon as it resolves)
    // or `appcastCheckTimer` (a 24h interval, far too coarse for "resume an
    // already-confirmed install promptly once the run finishes"). Only ever
    // running while genuinely needed keeps this from becoming a third
    // permanent background poll.
    private var installPollTimer: Timer?
    private let installPollInterval: TimeInterval = 15

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

        setUpAppcastUpdateChecker()
        startAppcastChecking()

        setUpUpdateInstallCoordinator()

        setUpPairingCode()
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

        // [specs/42 Task 2, AC-03] Grey means an action the person cannot take
        // right now, and nothing else. With automatic enabling on, AppKit greys
        // out every item that has no action, which made the menu's plain
        // information lines read as broken or as access lost. Off, each item
        // below owns its own `isEnabled`, and the default is enabled.
        menu.autoenablesItems = false

        // [specs/38, AC-02] The line a person already reads for status is also
        // the one they click to copy the pairing code, so the single action
        // pairing asks of them needs no second place to look. When there is
        // nothing to copy it keeps its normal look and simply does nothing on
        // a click, because it reports a status rather than offering an action.
        let line = PairingCodeMenu.statusLine(
            status: currentStatus,
            codeState: pairingCodeHolder?.state ?? .none,
            justCopied: pairingCodeJustCopied
        )

        let statusLineItem = NSMenuItem(
            title: line.title,
            action: line.isCopyAction ? #selector(copyPairingCode(_:)) : nil,
            keyEquivalent: ""
        )

        // [AC-04] Only the code-offering state gets a target, so only there
        // does a click copy. Every other state leaves the line without an
        // action and a click changes nothing. No do-nothing selector stands in
        // for that: having no action is the honest way to say there is nothing
        // to do, and a stub could later be given a body by accident.
        if line.isCopyAction {
            statusLineItem.target = self
        }

        // [specs/42 Task 1, AC-01/AC-02] One coloured dot beside the words,
        // in the one colour language `StatusIndicator` defines. The title is
        // untouched: the dot reinforces the line, it does not replace any of
        // it. `currentStatus` answers an indicator for every state, so this
        // line can never leave the status without a dot.
        statusLineItem.image = StatusIndicatorImage.image(for: currentStatus.indicator)

        menu.addItem(statusLineItem)

        // [AC-08] The specific reason the last URL-scheme pairing attempt
        // failed, surfaced as its own line rather than folded into
        // `currentStatus.menuStatusLine` — keeps `WorkerStatus` a small,
        // fixed set of display strings while still reporting the real
        // reason (never the raw pairing code or credential) in the menu.
        // [specs/42 Task 2, AC-03] It reports a reason, so it is drawn like
        // any other line. It has no action because there is nothing to click.
        if currentStatus == .notPaired, let pairingFailureDetail {
            let detailItem = NSMenuItem(
                title: "Pairing failed: \(pairingFailureDetail)",
                action: nil,
                keyEquivalent: ""
            )
            menu.addItem(detailItem)
        }

        // [Task 10, AC-12] Describes the verified, downloaded update — a
        // menu-bar prompt, not an automatic install.
        // [specs/42 Task 2, AC-03] It reports a version, so it is drawn like
        // any other line. The install item right below it is the action.
        if currentStatus == .updateAvailable, let pendingUpdate {
            let updateDetailItem = NSMenuItem(
                title: "Version \(pendingUpdate.version) is available",
                action: nil,
                keyEquivalent: ""
            )
            menu.addItem(updateDetailItem)

            // [Task 11, AC-13/AC-14] The actionable confirm-and-install
            // item this earlier line lacked. Its title/enabled state
            // reflects `updateInstallCoordinator`'s own state so the
            // operator sees the deferred-while-a-run-is-active case (AC-14)
            // without needing to click again once the run finishes.
            let installItem = NSMenuItem(
                title: installMenuItemTitle,
                action: #selector(installUpdate(_:)),
                keyEquivalent: ""
            )
            // [specs/42 Task 2, AC-05] The one honest grey in this menu: while
            // a run is still active, or while the handoff is already under
            // way, installing is an action the person genuinely cannot take
            // yet.
            switch updateInstallCoordinator?.state {
            case .some(.awaitingActiveRunToFinish), .some(.installHandedOff):
                installItem.isEnabled = false
            default:
                installItem.isEnabled = true
                installItem.target = self
            }
            menu.addItem(installItem)
        }

        menu.addItem(.separator())

        // AC-03: not-paired offers only these two items — no manual
        // pairing-code entry field or any other action. Tasks 4/10 add
        // status-specific lines above; nothing adds a new actionable menu
        // item yet, so every status currently shares this same two-item
        // action set.
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
        // triggers termination. Giving this item a target would move
        // termination to some other object, so it keeps none. With
        // `autoenablesItems` off nothing validates it any more, so it says
        // enabled itself; dispatch through the responder chain is unaffected.
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func refreshStatus() {
        // [Task 10, AC-12] A verified pending update takes priority over
        // every other status — once set this session it stays shown (Task
        // 11 owns clearing it, as part of actually acting on it).
        if pendingUpdate != nil {
            currentStatus = .updateAvailable
        } else {
            currentStatus = urlPairingOverrideStatus ?? WorkerStatus.from(pairing: pairingStatus, connection: connectionState)
        }
        // A newly paired app stops offering a code; an unpaired one keeps a
        // live one. Both are decided here so no other path has to remember.
        if currentStatus != .notPaired {
            pairingCodeHolder?.discard()
            pairingCodeJustCopied = false
        }

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

                // [specs/39 Task 7] `.pairedSettingUp` is an override set the
                // moment a credential is obtained, and it outranks the real
                // status in `refreshStatus()`. Once a configuration is stored
                // on disk the setup it describes is over, so the override has
                // to stand down or the menu would say "Paired, setting up…"
                // for the rest of the launch, even while the control plane has
                // the worker attached. Only a stored configuration clears it:
                // that is precisely the condition `.pairedSettingUp` was
                // waiting on.
                if pairing == .paired, self.urlPairingOverrideStatus == .pairedSettingUp {
                    self.urlPairingOverrideStatus = nil
                }

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

    // MARK: - Connection status polling

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

    // MARK: - Periodic signed-appcast check (Task 10, AC-11 / AC-12)

    private func setUpAppcastUpdateChecker() {
        let infoDictionary = Bundle.main.infoDictionary
        let appcastURL = AppcastURLProvider.appcastURL(infoDictionary: infoDictionary)
        let publicKeyBase64 = AppcastPublicKeyProvider.publicKeyBase64(infoDictionary: infoDictionary)
        let currentAppVersion = WorkerAppVersionReader.appVersion(infoDictionary: infoDictionary)

        appcastUpdateChecker = AppcastUpdateChecker(
            appcastURL: appcastURL,
            currentAppVersion: currentAppVersion,
            publicKeyBase64: publicKeyBase64,
            httpFetcher: URLSessionAppcastHTTPFetcher(),
            onUpdateAvailable: { [weak self] artifact in
                DispatchQueue.main.async {
                    self?.pendingUpdate = artifact
                    self?.refreshStatus()
                }
            },
            logError: { [weak self] message in
                DispatchQueue.main.async {
                    self?.logError("appcast: \(message)")
                }
            }
        )
    }

    private func startAppcastChecking() {
        guard appcastCheckTimer == nil else { return }

        let timer = Timer(timeInterval: appcastCheckInterval, repeats: true) { [weak self] _ in
            self?.appcastUpdateChecker?.checkNow()
        }
        RunLoop.main.add(timer, forMode: .common)
        appcastCheckTimer = timer

        appcastUpdateChecker?.checkNow()
    }

    // MARK: - Confirmed update install (Task 11, AC-13 / AC-14)

    private var installMenuItemTitle: String {
        switch updateInstallCoordinator?.state {
        case .some(.awaitingActiveRunToFinish):
            return "Install pending (waiting for run to finish)…"
        case .some(.installHandedOff):
            return "Installing…"
        case .none, .some(.idle), .some(.aborted):
            return "Install and Relaunch"
        }
    }

    private func setUpUpdateInstallCoordinator() {
        updateInstallCoordinator = UpdateInstallCoordinator(
            commandRunner: commandRunner,
            installExecutor: HelperScriptInstallExecutor(),
            onStateChange: { [weak self] state in
                DispatchQueue.main.async {
                    self?.handleUpdateInstallStateChange(state)
                }
            },
            log: { [weak self] message in
                DispatchQueue.main.async {
                    self?.logError("update install: \(message)")
                }
            }
        )
    }

    /// [AC-13] The operator activated "Install and Relaunch". Mirrors
    /// `applicationShouldTerminate(_:)`'s own AC-04/AC-05 shape exactly:
    /// dispatch the blocking `RunStateQuerier.query` off the main thread,
    /// then hop back to hand the result to the Core-side decision.
    @objc private func installUpdate(_ sender: Any?) {
        guard let pendingUpdate, let updateInstallCoordinator else { return }

        let binaryPath = workerBinaryPath
        let runner = commandRunner

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = RunStateQuerier.query(workerBinaryPath: binaryPath, runner: runner)

            DispatchQueue.main.async {
                guard self != nil else { return }
                updateInstallCoordinator.confirmInstall(artifact: pendingUpdate, runStateResult: result)
            }
        }
    }

    private func handleUpdateInstallStateChange(_ state: UpdateInstallCoordinator.State) {
        switch state {
        case .idle:
            break

        case .awaitingActiveRunToFinish:
            startInstallPollingIfNeeded()
            rebuildMenu()

        case .installHandedOff:
            // [AC-13] The helper has actually started (confirmed by
            // `HelperScriptInstallExecutor.beginInstall`'s own
            // `Process.isRunning` check before this state is ever reached).
            // Reuse the existing AC-04/AC-05 termination decision point
            // instead of a second parallel quit path -- `isInstallingUpdate`
            // tells `applicationShouldTerminate(_:)` to skip the redundant
            // active-run warning, since this gate already passed.
            stopInstallPolling()
            isInstallingUpdate = true
            NSApp.terminate(nil)

        case .aborted(let reason):
            stopInstallPolling()
            logError("update install aborted: \(reason)")
            rebuildMenu()
        }
    }

    private func startInstallPollingIfNeeded() {
        guard installPollTimer == nil else { return }

        let timer = Timer(timeInterval: installPollInterval, repeats: true) { [weak self] _ in
            self?.pollPendingInstall()
        }
        RunLoop.main.add(timer, forMode: .common)
        installPollTimer = timer
    }

    private func stopInstallPolling() {
        installPollTimer?.invalidate()
        installPollTimer = nil
    }

    /// [AC-14] Re-checks run state while an install is deferred. Safe to
    /// call unconditionally on every tick: `UpdateInstallCoordinator.runStateUpdated(_:)`
    /// itself no-ops unless it is currently `.awaitingActiveRunToFinish`.
    private func pollPendingInstall() {
        guard let updateInstallCoordinator else { return }

        let binaryPath = workerBinaryPath
        let runner = commandRunner

        DispatchQueue.global(qos: .utility).async {
            let result = RunStateQuerier.query(workerBinaryPath: binaryPath, runner: runner)

            DispatchQueue.main.async {
                updateInstallCoordinator.runStateUpdated(result)
            }
        }
    }

    // MARK: - Open Dashboard

    @objc private func openDashboard(_ sender: Any?) {
        let url = DashboardURLProvider.dashboardURL(infoDictionary: Bundle.main.infoDictionary)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Pairing code (specs/38, AC-01 / AC-02 / AC-07)

    /// Starts holding a code so an unpaired app has something to offer. Wired
    /// to the dashboard URL the bundle already resolves, which is the only
    /// control-plane address this app knows before it has ever paired.
    private func setUpPairingCode() {
        let controlPlane = DashboardURLProvider.dashboardURL(infoDictionary: Bundle.main.infoDictionary)

        pairingCodeHolder = PairingCodeHolder(
            poster: URLSessionPairingHTTPPoster(),
            controlPlaneURL: controlPlane
        )

        // [specs/39 Task 2] Where a redeemed code's credential and worker
        // identity go. [specs/39 Task 3, AC-03] `MacCodingAgentSetup` is
        // the coding-agent setup step it asks first: it auto-detects a
        // supported executable, falls back to `AgentSelectionAlertPrompt`
        // only when detection finds none, and answers once for this Mac.
        // A canceled prompt leaves nothing stored, so retention stops
        // before it writes and the next redemption asks again.
        macPairingRetention = MacPairingRetention(
            controlPlaneURL: controlPlane,
            workerBinaryPath: workerBinaryPath,
            commandRunner: commandRunner,
            agentResolver: MacCodingAgentSetup(
                commandRunner: commandRunner,
                selectionPrompt: AgentSelectionAlertPrompt()
            )
        )

        pairingCodeCopier = PairingCodeCopier(pasteboard: SystemPasteboard())
        startPairingLoop()
    }

    /// Ticks while this app is unpaired. Each tick does the one thing the
    /// current state calls for, decided by `PairingLoop`.
    private func startPairingLoop() {
        pairingLoopTimer?.invalidate()

        pairingLoopTimer = Timer.scheduledTimer(
            withTimeInterval: pairingLoopInterval,
            repeats: true
        ) { [weak self] _ in
            self?.runPairingLoopTick()
        }

        runPairingLoopTick()
    }

    private func stopPairingLoop() {
        pairingLoopTimer?.invalidate()
        pairingLoopTimer = nil
    }

    private func runPairingLoopTick() {
        guard let pairingCodeHolder else { return }

        switch PairingLoop.next(status: currentStatus, codeState: pairingCodeHolder.state) {
        case .idle:
            // Paired. Nothing to fetch and nothing to try, so stop asking.
            stopPairingLoop()
            pairingCodeHolder.discard()
            rebuildMenu()

        case .refreshCode:
            pairingCodeHolder.refreshIfNeeded { [weak self] _ in
                DispatchQueue.main.async { self?.rebuildMenu() }
            }

        case .attemptCompletion(let code):
            attemptPairingCompletion(with: code)
        }
    }

    /// Tries to finish pairing with the held code. A refusal means no owner has
    /// redeemed it yet, which is an ordinary answer and leaves the code in
    /// place; a success means one has, and the same call already returned the
    /// credential. Nothing is shown to the person for a refusal, because "not
    /// yet" is not a failure they caused or can act on.
    private func attemptPairingCompletion(with code: String) {
        guard !pairingCompletionInFlight else { return }

        pairingCompletionInFlight = true

        let endpoint = DashboardURLProvider
            .dashboardURL(infoDictionary: Bundle.main.infoDictionary)
            .appendingPathComponent("worker_pairings")

        let body = PairingCompletionRequestBody.build(code: code, selfReport: selfReport())

        pairingCompletionPoster.post(url: endpoint, jsonObject: body) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }

                self.pairingCompletionInFlight = false

                let statusCode = (response as? HTTPURLResponse)?.statusCode

                switch PairingCompletionResponseParser.parse(
                    statusCode: statusCode,
                    data: data,
                    transportError: error
                ) {
                case .success(let completed):
                    // [specs/39 Task 2, AC-01] An owner redeemed it, so the
                    // control plane issued this Mac a credential and a worker
                    // identity. specs/38 threw both away and told the person to
                    // continue in the dashboard, because a worker paired this
                    // way has no project and the worker configuration required
                    // one. Task 1 of this slice made a projectless
                    // configuration valid, so the app keeps what it was issued
                    // and finishes the setup itself. It reports
                    // `.pairedSettingUp` like every other pairing does.
                    self.pairingCodeHolder?.discard()
                    self.pairingCodeJustCopied = false
                    self.urlPairingOverrideStatus = .pairedSettingUp
                    self.stopPairingLoop()
                    self.refreshStatus()

                    // `retain` shells out to `bin/worker rpc` and blocks until
                    // the release answers, so it runs off the main thread —
                    // the same split `refreshPairingStatus()` and the
                    // `RunStateQuerier` poll already use. Every status and menu
                    // mutation stays above, on the main thread.
                    if let retention = self.macPairingRetention {
                        let credential = completed.credential
                        let worker = completed.worker

                        DispatchQueue.global(qos: .utility).async { [weak self] in
                            let stored = retention.retain(credential: credential, worker: worker)

                            // A stored configuration is exactly the condition
                            // `.pairedSettingUp` was waiting on, and nothing
                            // else observes it: `refreshPairingStatus()` runs
                            // once at launch, when this app was still unpaired.
                            // Without re-checking here the menu would sit on
                            // "Paired, setting up…" for the rest of the launch
                            // while the control plane had the worker attached,
                            // and the connection polling that turns an
                            // attachment into "Connected" would never start.
                            // Re-checking is what makes the person see the
                            // pairing finish without relaunching the app.
                            guard stored else { return }

                            DispatchQueue.main.async { self?.refreshPairingStatus() }
                        }
                    }

                case .failure:
                    // Not yet. Keep the code and keep waiting.
                    break
                }
            }
        }
    }

    private func selfReport() -> WorkerSelfReport {
        WorkerSelfReport(
            osFamily: "macos",
            osMajor: String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
            protocolVersion: ProtocolVersionQuerier.query(
                workerBinaryPath: workerBinaryPath,
                runner: commandRunner
            ),
            appVersion: WorkerAppVersionReader.appVersion(infoDictionary: Bundle.main.infoDictionary)
        )
    }

    @objc private func copyPairingCode(_ sender: Any?) {
        guard let pairingCodeHolder, let pairingCodeCopier else { return }

        // Only a click reaches the clipboard. Nothing copies on a schedule or
        // as a side effect of the menu opening.
        pairingCodeJustCopied = pairingCodeCopier.copy(from: pairingCodeHolder.state)
        rebuildMenu()
    }

    // MARK: - Quit (AC-04 / AC-05)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workerProcessController, workerProcessController.isRunning else {
            return .terminateNow
        }

        // [Task 11] `updateInstallCoordinator` already satisfied the
        // AC-13/AC-14 active-run gate -- immediately, or by waiting for a
        // deferred run to reach a terminal state -- before ever handing off
        // to the installer and calling `NSApp.terminate(nil)` on this app's
        // own behalf. Re-querying and re-warning here would be redundant,
        // not an extra safety check, so this path stops the embedded worker
        // exactly like any other quit and skips straight to that.
        if isInstallingUpdate {
            stopEmbeddedWorkerAndReply()
            return .terminateLater
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
