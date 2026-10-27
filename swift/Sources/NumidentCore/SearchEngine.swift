import Foundation
import os

public struct SearchOptions: Sendable {
    /// Files read at the same time. 1 for spinning disks, 2–4 for SSDs.
    public var concurrency: Int = 2
    /// Search stops once this many matches have been found.
    public var resultCap: Int = 10_000
    /// Progress (and batched match) events per second ≈ 1 / interval.
    public var progressInterval: Double = 0.25
    public var chunkSize: Int = 4 << 20

    public init(concurrency: Int = 2, resultCap: Int = 10_000, progressInterval: Double = 0.25, chunkSize: Int = 4 << 20) {
        self.concurrency = concurrency
        self.resultCap = resultCap
        self.progressInterval = progressInterval
        self.chunkSize = chunkSize
    }
}

public enum SearchMode: Sendable {
    case fullScan
    case ssnLookup
}

public struct SetProgress: Sendable {
    public var done: Int64
    public var total: Int64
    public var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 1 }
}

public struct SearchProgress: Sendable {
    public var mode: SearchMode
    public var doneBytes: Int64
    public var totalBytes: Int64
    public var perSet: [DatasetKind: SetProgress]
    public var currentFiles: [String]
    public var filesDone: Int
    public var filesTotal: Int
    public var matchCount: Int
    public var elapsed: Double
    public var bytesPerSecond: Double
    public var etaSeconds: Double?

    public var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 1 }
}

public enum FileOutcomeState: Sendable, Equatable {
    case notStarted
    case done
    case cancelled
    case failed(String)
}

public struct FileOutcome: Sendable, Identifiable {
    public let file: CatalogFile
    public var state: FileOutcomeState
    /// e.g. "binary search (2 sorted runs)", "full scan", or "full scan (file not sortable)".
    public var method: String
    public var id: String { file.id }
}

public struct SearchSummary: Sendable {
    public let mode: SearchMode
    public let cancelled: Bool
    public let hitCap: Bool
    public let matchCount: Int
    public let bytesRead: Int64
    public let totalBytes: Int64
    public let elapsed: Double
    public let outcomes: [FileOutcome]
    public let skipped: [DatasetKind: String]

    public var failed: [FileOutcome] { outcomes.filter { if case .failed = $0.state { return true }; return false } }
    public var bytesPerSecond: Double { elapsed > 0 ? Double(bytesRead) / elapsed : 0 }
}

public enum SearchEvent: Sendable {
    case started(SearchProgress)
    case progress(SearchProgress)
    case matches([NumidentRecord])
    case fileFailed(String, String)
    case finished(SearchSummary)
}

/// Shared mutable search state, guarded by one lock. Workers touch it once per chunk.
final class SearchState: @unchecked Sendable {
    private struct S {
        var doneByFile: [String: Int64] = [:]
        var current: Set<String> = []
        var pending: [NumidentRecord] = []
        var matchCount = 0
        var hitCap = false
        var outcomes: [String: FileOutcome] = [:]
        var bytesRead: Int64 = 0
        var filesDone = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: S())
    let files: [CatalogFile]
    let cap: Int
    let cancel: CancelToken
    let start = Date()
    let mode: SearchMode
    private let rate = OSAllocatedUnfairLock(initialState: RateEstimator())
    let buffers: BufferPool
    let scanSlots: DispatchSemaphore

    init(files: [CatalogFile], cap: Int, mode: SearchMode, chunkSize: Int, concurrency: Int, cancel: CancelToken) {
        self.cancel = cancel
        self.buffers = BufferPool(chunkSize: chunkSize)
        self.scanSlots = DispatchSemaphore(value: max(1, concurrency))
        self.files = files
        self.cap = cap
        self.mode = mode
        lock.withLock { s in
            for f in files { s.outcomes[f.path] = FileOutcome(file: f, state: .notStarted, method: "") }
        }
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    func begin(_ f: CatalogFile, method: String) {
        lock.withLock { s in
            s.current.insert(f.name)
            s.outcomes[f.path]?.method = method
        }
    }

    func setMethod(_ f: CatalogFile, _ method: String) {
        lock.withLock { $0.outcomes[f.path]?.method = method }
    }

    func addBytes(_ f: CatalogFile, _ n: Int) {
        lock.withLock { s in
            s.doneByFile[f.path, default: 0] += Int64(n)
            s.bytesRead += Int64(n)
        }
    }

    /// Records a match; returns false once the cap is reached.
    @discardableResult
    func addMatch(_ r: NumidentRecord) -> Bool {
        let keepGoing: Bool = lock.withLock { s in
            if s.matchCount >= cap { s.hitCap = true; return false }
            s.pending.append(r)
            s.matchCount += 1
            if s.matchCount >= cap { s.hitCap = true; return false }
            return true
        }
        if !keepGoing { cancel.cancel() }
        return keepGoing
    }

    func finish(_ f: CatalogFile, _ state: FileOutcomeState, countAsDone: Bool) {
        lock.withLock { s in
            s.current.remove(f.name)
            s.outcomes[f.path]?.state = state
            if countAsDone {
                // Binary-search files count as fully covered for the progress bar.
                s.doneByFile[f.path] = f.size
                s.filesDone += 1
            } else if case .failed = state {
                s.filesDone += 1
            }
        }
    }

    func takePending() -> [NumidentRecord] {
        lock.withLock { s in
            let p = s.pending
            s.pending.removeAll(keepingCapacity: true)
            return p
        }
    }

    func snapshot() -> SearchProgress {
        let total = totalBytes
        let (byFile, current, matches, filesDone) = lock.withLock { s in
            (s.doneByFile, s.current.sorted(), s.matchCount, s.filesDone)
        }
        var perSet: [DatasetKind: SetProgress] = [:]
        var done: Int64 = 0
        for f in files {
            let d = min(byFile[f.path] ?? 0, f.size)
            done += d
            perSet[f.kind, default: SetProgress(done: 0, total: 0)].done += d
            perSet[f.kind, default: SetProgress(done: 0, total: 0)].total += f.size
        }
        let elapsed = Date().timeIntervalSince(start)
        let doneBytes = done
        let bps = rate.withLock { $0.update(bytes: doneBytes, at: elapsed) }
        let eta: Double? = bps > 0 && done < total ? Double(total - done) / bps : nil
        return SearchProgress(mode: mode, doneBytes: done, totalBytes: total, perSet: perSet,
                              currentFiles: current, filesDone: filesDone, filesTotal: files.count,
                              matchCount: matches, elapsed: elapsed, bytesPerSecond: bps, etaSeconds: eta)
    }

    func summary(cancelled: Bool, skipped: [DatasetKind: String]) -> SearchSummary {
        let snap = snapshot()
        return lock.withLock { s in
            var outcomes = files.compactMap { s.outcomes[$0.path] }
            if cancelled || s.hitCap {
                for i in outcomes.indices where outcomes[i].state == .notStarted { outcomes[i].state = .cancelled }
            }
            return SearchSummary(mode: mode, cancelled: cancelled && !s.hitCap, hitCap: s.hitCap,
                                 matchCount: s.matchCount, bytesRead: s.bytesRead, totalBytes: snap.totalBytes,
                                 elapsed: snap.elapsed, outcomes: outcomes, skipped: skipped)
        }
    }
}

/// Hands each worker a reusable 4 MB buffer; at most `concurrency` buffers ever exist.
final class BufferPool: @unchecked Sendable {
    private let free = OSAllocatedUnfairLock(initialState: [ScanBuffer]())
    let chunkSize: Int
    init(chunkSize: Int) { self.chunkSize = chunkSize }
    func take() -> ScanBuffer { free.withLock { $0.popLast() } ?? ScanBuffer(chunkSize: chunkSize) }
    func give(_ b: ScanBuffer) { free.withLock { $0.append(b) } }
}

/// Exponentially smoothed throughput so the ETA doesn't jump around.
struct RateEstimator {
    private var lastBytes: Int64 = 0
    private var lastTime: Double = 0
    private var smoothed: Double = 0

    mutating func update(bytes: Int64, at t: Double) -> Double {
        let dt = t - lastTime
        guard dt > 0.05 else { return smoothed }
        let inst = Double(bytes - lastBytes) / dt
        smoothed = smoothed == 0 ? inst : smoothed * 0.7 + inst * 0.3
        lastBytes = bytes
        lastTime = t
        return smoothed
    }
}

/// A running search. `cancel()` stops the workers within one chunk; the event stream then still
/// delivers the matches found so far and a `.finished` summary marked cancelled.
public final class SearchHandle: @unchecked Sendable {
    public let events: AsyncStream<SearchEvent>
    private let token: CancelToken

    init(events: AsyncStream<SearchEvent>, token: CancelToken) {
        self.events = events
        self.token = token
    }

    public func cancel() { token.cancel() }
    public var isCancelled: Bool { token.isCancelled }
}

public enum SearchEngine {
    private static let ioQueue = DispatchQueue(label: "numident.io", qos: .userInitiated, attributes: .concurrent)

    /// Runs a search over `files` and streams events. Cancelling the consuming task (or dropping the
    /// stream) stops all workers within one chunk.
    public static func search(_ query: SearchQuery, files: [CatalogFile],
                              options: SearchOptions = SearchOptions()) -> AsyncStream<SearchEvent> {
        start(query, files: files, options: options).events
    }

    /// Starts a search and returns a handle that can cancel it while the caller keeps reading events.
    public static func start(_ query: SearchQuery, files: [CatalogFile],
                             options: SearchOptions = SearchOptions()) -> SearchHandle {
        let token = CancelToken()
        let events = AsyncStream<SearchEvent>(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await run(query, files: files, options: options, token: token, continuation: continuation)
            }
            continuation.onTermination = { _ in
                token.cancel()
                task.cancel()
            }
        }
        return SearchHandle(events: events, token: token)
    }

    /// Convenience: runs a search to completion and returns all matches plus the summary.
    public static func collect(_ query: SearchQuery, files: [CatalogFile],
                               options: SearchOptions = SearchOptions()) async -> ([NumidentRecord], SearchSummary?) {
        var out: [NumidentRecord] = []
        var summary: SearchSummary?
        for await e in search(query, files: files, options: options) {
            switch e {
            case .matches(let m): out += m
            case .finished(let s): summary = s
            default: break
            }
        }
        return (out, summary)
    }

    static func run(_ query: SearchQuery, files: [CatalogFile], options: SearchOptions, token: CancelToken,
                    continuation: AsyncStream<SearchEvent>.Continuation) async {
        let applicable = query.applicableKinds
        let skipped = query.skippedReasons.filter { k, _ in files.contains { $0.kind == k } }
        let targets = files.filter { applicable.contains($0.kind) && $0.isUsable }
        let mode: SearchMode = query.hasValidSSN ? .ssnLookup : .fullScan
        let state = SearchState(files: targets, cap: max(1, options.resultCap), mode: mode, chunkSize: options.chunkSize,
                                concurrency: options.concurrency, cancel: token)
        let compiled = CompiledQuery(query)

        continuation.yield(.started(state.snapshot()))

        let ticker = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(options.progressInterval * 1_000_000_000))
                if Task.isCancelled { break }
                let m = state.takePending()
                if !m.isEmpty { continuation.yield(.matches(m)) }
                continuation.yield(.progress(state.snapshot()))
            }
        }

        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                var queue = targets.makeIterator()
                let width = mode == .ssnLookup ? max(options.concurrency, 8) : max(1, options.concurrency)
                func addNext() -> Bool {
                    guard !state.cancel.isCancelled, let f = queue.next() else { return false }
                    group.addTask {
                        await process(f, mode: mode, compiled: compiled, state: state, options: options,
                                      continuation: continuation)
                    }
                    return true
                }
                for _ in 0..<width { if !addNext() { break } }
                while await group.next() != nil { _ = addNext() }
            }
        } onCancel: {
            state.cancel.cancel()
        }

        ticker.cancel()
        let userCancelled = Task.isCancelled || state.cancel.isCancelled
        let m = state.takePending()
        if !m.isEmpty { continuation.yield(.matches(m)) }
        continuation.yield(.progress(state.snapshot()))
        continuation.yield(.finished(state.summary(cancelled: userCancelled, skipped: skipped)))
        continuation.finish()
    }

    /// Runs one file's blocking I/O on the I/O queue and records its outcome.
    static func process(_ f: CatalogFile, mode: SearchMode, compiled: CompiledQuery, state: SearchState,
                        options: SearchOptions, continuation: AsyncStream<SearchEvent>.Continuation) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                defer { done.resume() }
                do {
                    if mode == .ssnLookup, let ssn = compiled.ssnBytes {
                        state.begin(f, method: "binary search")
                        if let result = try SSNIndex.lookup(path: f.path, kind: f.kind, ssn: ssn, cancel: state.cancel) {
                            state.setMethod(f, result.method)
                            for h in result.hits {
                                let r = NumidentRecord(kind: f.kind, fileName: f.name, offset: h.offset, bytes: h.bytes)
                                if compiled.matches(r) && !state.addMatch(r) { break }
                            }
                            state.finish(f, .done, countAsDone: true)
                            return
                        }
                        state.setMethod(f, "full scan (file not sortable)")
                    } else {
                        state.begin(f, method: "full scan")
                    }
                    // Lookups run many files at once; full scans are limited to `concurrency` readers.
                    state.scanSlots.wait()
                    defer { state.scanSlots.signal() }
                    let buffer = state.buffers.take()
                    defer { state.buffers.give(buffer) }
                    try LineScanner.scan(path: f.path, buffer: buffer, cancel: state.cancel,
                                         progress: { state.addBytes(f, $0) }) { line, offset in
                        if compiled.matches(line, kind: f.kind) {
                            let r = NumidentRecord(kind: f.kind, fileName: f.name, offset: offset, bytes: Array(line))
                            state.addMatch(r)
                        }
                    }
                    state.finish(f, .done, countAsDone: true)
                } catch ScanError.cancelled {
                    state.finish(f, .cancelled, countAsDone: false)
                } catch {
                    let msg = (error as? ScanError)?.description ?? error.localizedDescription
                    state.finish(f, .failed(msg), countAsDone: false)
                    continuation.yield(.fileFailed(f.name, msg))
                }
            }
        }
    }
}
