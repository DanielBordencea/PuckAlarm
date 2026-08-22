import CoreNFC
import Foundation

/// Reads the puck's tag identifier using Core NFC.
///
/// The sheet in the screenshot — "Ready to Scan" with the checkmark — is drawn by iOS, not
/// by this app. Starting an `NFCTagReaderSession` is what summons it. The only part we
/// control is `alertMessage`, which becomes the line under the title; setting it to
/// "Alarm Stopped" just before invalidating is what produces the success state.
final class PuckReader: NSObject, @unchecked Sendable {
    enum Failure: LocalizedError {
        case unavailable
        case cancelled
        case unreadableTag
        case system(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "This device can't read NFC tags, or NFC isn't enabled for this build."
            case .cancelled:
                "Scan cancelled."
            case .unreadableTag:
                "That tag didn't return an identifier. Try a different tag."
            case .system(let message):
                message
            }
        }
    }

    static var isAvailable: Bool {
        NFCTagReaderSession.readingAvailable
    }

    /// Core NFC delivers delegate callbacks on its own serial queue while `readIdentifier`
    /// is suspended on the caller's, so this state is genuinely reached from two contexts.
    /// A lock is the honest expression of that; an actor could not satisfy the nonisolated
    /// delegate protocol without hopping back out again.
    private let lock = NSLock()
    private var session: NFCTagReaderSession?
    private var continuation: CheckedContinuation<String, Error>?
    private var successMessage = ""

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Presents the system scan sheet and resolves with the tag identifier as uppercase hex.
    ///
    /// - Parameters:
    ///   - prompt: shown under "Ready to Scan" while waiting for a tag.
    ///   - successMessage: replaces the prompt when a tag is accepted; iOS shows it next to
    ///     the checkmark.
    func readIdentifier(
        prompt: String,
        successMessage: String
    ) async throws -> String {
        guard Self.isAvailable else { throw Failure.unavailable }

        withLock { self.successMessage = successMessage }

        return try await withCheckedThrowingContinuation { continuation in
            // NTAG213/215/216 and most stickers are ISO14443 Type A; the other two options
            // cost nothing and cover ISO15693 cards and FeliCa.
            guard let session = NFCTagReaderSession(
                pollingOption: [.iso14443, .iso15693, .iso18092],
                delegate: self,
                queue: nil
            ) else {
                continuation.resume(throwing: Failure.unavailable)
                return
            }

            withLock {
                self.continuation = continuation
                self.session = session
            }
            session.alertMessage = prompt
            session.begin()
        }
    }

    /// Resumes the continuation exactly once. Both the success path and the invalidation
    /// callback land here, and on success they land here twice — invalidating a session
    /// after a successful read also fires `didInvalidateWithError`.
    private func finish(with result: Result<String, Error>) {
        let continuation: CheckedContinuation<String, Error>? = withLock {
            defer {
                self.continuation = nil
                self.session = nil
            }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

extension PuckReader: NFCTagReaderSessionDelegate {
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        // Nothing to do; the system sheet is now on screen.
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        let failure: Error
        if let readerError = error as? NFCReaderError {
            switch readerError.code {
            case .readerSessionInvalidationErrorUserCanceled,
                 .readerSessionInvalidationErrorSessionTimeout:
                failure = Failure.cancelled
            case .readerSessionInvalidationErrorFirstNDEFTagRead,
                 .readerSessionInvalidationErrorSessionTerminatedUnexpectedly:
                // We invalidate on success too; if the continuation is already gone this
                // resume is a no-op.
                failure = Failure.cancelled
            default:
                failure = Failure.system(readerError.localizedDescription)
            }
        } else {
            failure = Failure.system(error.localizedDescription)
        }
        finish(with: .failure(failure))
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else {
            session.restartPolling()
            return
        }

        guard let identifier = Self.identifier(for: tag) else {
            session.alertMessage = "That tag has no readable ID. Try another."
            session.restartPolling()
            return
        }

        // Core NFC hands this callback back on its own serial queue and `NFCTagReaderSession`
        // is not `Sendable`, so the capture has to be spelled out as unsafe rather than
        // silently allowed.
        nonisolated(unsafe) let session = session

        // Connecting is not required to read the UID, but it confirms the tag is really
        // in range rather than a fleeting poll, which avoids false positives when the
        // phone brushes past the dock.
        session.connect(to: tag) { [weak self] error in
            guard let self else { return }
            if let error {
                session.invalidate(errorMessage: error.localizedDescription)
                self.finish(with: .failure(Failure.system(error.localizedDescription)))
                return
            }
            session.alertMessage = self.withLock { self.successMessage }
            session.invalidate()
            self.finish(with: .success(identifier))
        }
    }

    /// Every tag family exposes its unique id under a different name.
    private static func identifier(for tag: NFCTag) -> String? {
        let data: Data
        switch tag {
        case .miFare(let mifare):
            data = mifare.identifier
        case .iso7816(let iso7816):
            data = iso7816.identifier
        case .iso15693(let iso15693):
            data = iso15693.identifier
        case .feliCa(let feliCa):
            data = feliCa.currentIDm
        @unknown default:
            return nil
        }
        guard !data.isEmpty else { return nil }
        return data.map { String(format: "%02X", $0) }.joined()
    }
}
