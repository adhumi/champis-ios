import Foundation
import Synchronization

/// Téléchargements de fichiers entiers par `URLSession` (configuration de fond en production :
/// reprise après fermeture, progression). Les événements sortent par un `AsyncStream` consommé sur
/// le MainActor par `OfflineModel`. Rien d'autre ne tourne en arrière-plan dans l'app.
nonisolated final class DownloadManager: NSObject, URLSessionDownloadDelegate, Sendable {
    nonisolated enum Outcome: Sendable {
        case progress(written: Int64, expected: Int64)
        case finished(URL)
        case failed(String)
    }

    nonisolated struct Event: Sendable {
        let tag: String
        let outcome: Outcome
    }

    private struct Pending {
        let tag: String
        let destination: URL
        var finished = false
    }

    private struct State {
        var tasks: [Int: Pending] = [:]
    }

    static let backgroundIdentifier = "fr.adhumi.champis.offline"

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let state = Mutex(State())
    private nonisolated(unsafe) var session: URLSession!

    /// `configuration` : de fond par défaut ; les tests passent une configuration éphémère.
    init(configuration: URLSessionConfiguration? = nil) {
        let (stream, cont) = AsyncStream.makeStream(of: Event.self)
        events = stream
        continuation = cont
        super.init()
        let config = configuration ?? {
            let c = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
            c.isDiscretionary = false
            c.sessionSendsLaunchEvents = true
            return c
        }()
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Lance le téléchargement ; le fichier sera déplacé à `destination` une fois complet.
    func download(_ url: URL, to destination: URL, tag: String) {
        let task = session.downloadTask(with: url)
        state.withLock { $0.tasks[task.taskIdentifier] = Pending(tag: tag, destination: destination) }
        task.resume()
    }

    func cancelAll() {
        session.getAllTasks { tasks in
            for task in tasks {
                task.cancel()
            }
        }
    }

    // MARK: URLSessionDownloadDelegate (files de la session, hors MainActor)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let pending = state.withLock({ $0.tasks[downloadTask.taskIdentifier] }) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            state.withLock { $0.tasks[downloadTask.taskIdentifier]?.finished = true }
            continuation.yield(Event(tag: pending.tag, outcome: .failed("HTTP \(status)")))
            return
        }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: pending.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: pending.destination.path(percentEncoded: false)) {
                try manager.removeItem(at: pending.destination)
            }
            try manager.moveItem(at: location, to: pending.destination)
            state.withLock { $0.tasks[downloadTask.taskIdentifier]?.finished = true }
            continuation.yield(Event(tag: pending.tag, outcome: .finished(pending.destination)))
        } catch {
            state.withLock { $0.tasks[downloadTask.taskIdentifier]?.finished = true }
            continuation.yield(Event(tag: pending.tag, outcome: .failed(error.localizedDescription)))
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let pending = state.withLock({ $0.tasks[downloadTask.taskIdentifier] }) else { return }
        continuation.yield(Event(tag: pending.tag, outcome: .progress(written: totalBytesWritten, expected: totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let pending = state.withLock { $0.tasks.removeValue(forKey: task.taskIdentifier) }
        guard let pending, !pending.finished, let error else { return }
        continuation.yield(Event(tag: pending.tag, outcome: .failed(error.localizedDescription)))
    }
}
