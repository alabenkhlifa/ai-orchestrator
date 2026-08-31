import Foundation

/// [specs/40 Task 4] One cycle of the reverse hop this app never had: read the
/// request the embedded release is holding, ask the person to point at a
/// folder, and write the answer back.
///
/// The two ends of the exchange are files under the release's own storage
/// root, because the release and this app are two processes on one machine
/// with no channel between them and a managed Mac's firewall refuses the one
/// the release ships (see `PendingSelectionQuerier` for why neither `rpc` nor
/// `eval` can carry this). Everything path-dependent happens on the release's
/// side of that exchange. This side chooses a folder and hands the path over,
/// and that is all it ever does with it.
///
/// ## The path is not kept
///
/// The chosen path lives in one local variable, from the picker's return to
/// the answer file, and nowhere else. It is not a property, it is not passed
/// to anything else, and no line in this type logs at any level.
///
/// ## One panel
///
/// The app polls every two seconds and a person takes tens of seconds to
/// choose a folder, so the arithmetic of a naive poll is a stack of panels.
/// Two things prevent that. Every cycle runs on one serial queue, so a cycle
/// blocked in the panel holds every later tick behind it, and `handled` names
/// the last request this app acted on, so the ticks that were held do not
/// re-open a panel for it when they finally run.
///
/// `handled` is deliberately not cleared once the answer is written. The
/// release removes the pending file when it takes the answer, but it polls for
/// that answer twice a second, so for up to half a second the file still names
/// a request this app has already answered. Clearing the mark would open a
/// second panel in exactly that window.
///
/// ## Threads
///
/// `respondToPendingSelection` returns at once and the work runs on this
/// object's own serial queue, so a timer on the main thread never waits on a
/// file read or on a person. The panel itself must be on the main thread, and
/// `NSOpenPanelWorkspaceFolderPicker` already owns that hop for its other
/// caller, so this type never touches AppKit and never dispatches to main. It
/// must also never be called with the main thread blocked waiting on it: the
/// picker's hop to main would then have nowhere to run.
///
/// Every read and write of `handled` happens on that one serial queue, which
/// is what makes it safe without a lock.
///
/// ## What a disappearing request means here
///
/// The release removes the pending file when the request ends for any reason,
/// including a cancellation or a timeout while the panel is open.
/// `WorkspaceFolderPicking` is synchronous and an `NSOpenPanel` cannot be
/// dismissed from this target, so the panel stays up until the person answers
/// it. What can be decided is whether that answer is written at all, and it is
/// not: the pending file is read again after the picker returns, and an answer
/// is written only while the request it belongs to is still the one open.
///
/// That guard is there for the path, not for the protocol. The release already
/// refuses an answer naming a request it is no longer holding, so writing one
/// buys nothing. What it would cost is real: `selection_answer.json` is the
/// only place a path is ever written and it is meant to exist for about one
/// poll interval, and the release deletes it only while it is polling for an
/// answer. An answer written for a dead request, with no request open behind
/// it, would sit on disk holding a path until some later request or the next
/// release start cleared it. A cancellation is held back for the same reason,
/// so that one rule covers both answers rather than two rules that could
/// drift.
public final class RepositorySelectionResponder {
    private let picker: WorkspaceFolderPicking
    private let queue = DispatchQueue(
        label: "com.sddorchestrator.worker.repository-selection",
        qos: .userInitiated
    )

    /// The last request a panel was opened for. Touched only on `queue`.
    private var handled: String?

    public init(picker: WorkspaceFolderPicking) {
        self.picker = picker
    }

    /// Runs one cycle for whatever the release is holding right now, and
    /// returns immediately. `homeOverride` names the storage root, the same
    /// way every other path in this app takes one; the app itself passes
    /// nothing. `completion` runs on the responder's own queue once the cycle
    /// is over, which is how the tests wait for a cycle instead of guessing at
    /// a duration.
    public func respondToPendingSelection(
        homeOverride: String? = nil,
        completion: (() -> Void)? = nil
    ) {
        queue.async { [weak self] in
            self?.respondNow(homeOverride: homeOverride)
            completion?()
        }
    }

    private func respondNow(homeOverride: String?) {
        // Nothing is open. This is the ordinary case, several times a minute,
        // for the whole life of the app.
        guard let pending = PendingSelectionQuerier.query(workerHomeOverride: homeOverride) else { return }

        // Already asked. Either the panel is open right now, or it has been
        // answered and the release has not yet noticed.
        guard pending.requestID != handled else { return }

        handled = pending.requestID

        // The one place a chosen path exists in this app. It goes straight
        // into the answer file and is not held afterwards.
        let chosen = picker.pickWorkspaceFolder()

        // Minutes can pass inside that call, so the request it belongs to is
        // read again rather than assumed. Nothing is written for a request
        // that has since been cancelled, timed out, or replaced.
        guard stillOpen(pending.requestID, homeOverride: homeOverride) else { return }

        if let chosen {
            _ = SelectionAnswerWriter.write(
                requestID: pending.requestID,
                path: chosen,
                homeOverride: homeOverride
            )
        } else {
            _ = SelectionAnswerWriter.writeCancellation(
                requestID: pending.requestID,
                homeOverride: homeOverride
            )
        }
    }

    private func stillOpen(_ requestID: String, homeOverride: String?) -> Bool {
        PendingSelectionQuerier.query(workerHomeOverride: homeOverride)?.requestID == requestID
    }
}
