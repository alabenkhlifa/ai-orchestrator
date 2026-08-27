import Foundation

/// What the menu's first line should say, and whether clicking it copies.
///
/// The status line is already the thing a person reads to find out where
/// pairing stands, so it is also the thing they click to take the one action
/// pairing asks of them. The code is roughly eighty opaque characters: it
/// cannot be read aloud or typed, so the clipboard is the only usable way to
/// move it, and showing it in full would only crowd the menu.
public struct PairingCodeMenuLine: Equatable, Sendable {
    public let title: String
    /// The code to place on the clipboard, or `nil` when this line is only a
    /// status and clicking it should do nothing.
    public let copyableCode: String?

    public var isCopyAction: Bool { copyableCode != nil }

    public init(title: String, copyableCode: String?) {
        self.title = title
        self.copyableCode = copyableCode
    }
}

public enum PairingCodeMenu {
    /// Builds the status line for the current pairing and code state.
    ///
    /// Only an unpaired app offers a code. Every other status is a plain
    /// status line, because a paired worker has nothing to pair and offering a
    /// stale action there would be worse than offering none.
    public static func statusLine(
        status: WorkerStatus,
        codeState: PairingCodeState,
        justCopied: Bool = false
    ) -> PairingCodeMenuLine {
        guard status == .notPaired else {
            return PairingCodeMenuLine(title: status.menuStatusLine, copyableCode: nil)
        }

        switch codeState {
        case .held(let code) where justCopied:
            return PairingCodeMenuLine(
                title: "Pairing code copied — paste it in the dashboard",
                copyableCode: code.value
            )

        case .held(let code):
            return PairingCodeMenuLine(
                title: "Not paired — click to copy your pairing code",
                copyableCode: code.value
            )

        case .unreachable:
            // Named rather than silent: a person who sees no code deserves to
            // know the app could not reach the control plane, not to wonder
            // whether they missed something.
            return PairingCodeMenuLine(
                title: "Not paired — can't reach the control plane",
                copyableCode: nil
            )

        case .none:
            return PairingCodeMenuLine(title: status.menuStatusLine, copyableCode: nil)
        }
    }
}

/// The seam the clipboard is written through, so a test can prove nothing is
/// ever written without the person asking.
public protocol Pasteboarding: AnyObject {
    func write(_ string: String)
}

/// Copies the held code, and only when asked.
///
/// Nothing here runs on a schedule or as a side effect of building the menu.
/// A person's click is the only thing that reaches the clipboard, which is why
/// `copy(from:)` is the single entry point and it takes the state rather than
/// reading any of its own.
public final class PairingCodeCopier {
    private let pasteboard: Pasteboarding

    public init(pasteboard: Pasteboarding) {
        self.pasteboard = pasteboard
    }

    /// Writes the full code and reports whether anything was written. Returns
    /// `false` when there is nothing valid to copy, so the caller can leave the
    /// menu saying what it already said instead of claiming a copy happened.
    @discardableResult
    public func copy(from state: PairingCodeState) -> Bool {
        guard case .held(let code) = state else { return false }

        pasteboard.write(code.value)
        return true
    }
}
