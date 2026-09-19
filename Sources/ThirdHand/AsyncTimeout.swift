import Foundation

/// Unlike a task group, this deadline does not wait for an uncooperative child.
/// Callers must check cancellation before using the returned data for input.
@MainActor
enum AsyncTimeout {
    static func run<T>(seconds: TimeInterval, message: String,
                       onTimeout: @escaping @MainActor () -> Void = {},
                       operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                race.continuation = continuation
                race.work = Task {
                    do { race.finish(.success(try await operation())) }
                    catch { race.finish(.failure(error)) }
                }
                race.timer = Task {
                    do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
                    catch { return }
                    guard race.continuation != nil else { return }
                    onTimeout()
                    race.finish(.failure(ControllerError.invalid(message)))
                }
            }
        } onCancel: {
            Task { @MainActor in race.finish(.failure(CancellationError())) }
        }
    }

    private final class Race<T> {
        var continuation: CheckedContinuation<T, Error>?
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
        func finish(_ result: Result<T, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            work?.cancel()
            timer?.cancel()
            work = nil
            timer = nil
            continuation.resume(with: result)
        }
    }
}
