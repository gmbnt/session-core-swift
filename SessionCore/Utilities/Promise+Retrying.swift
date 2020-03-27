import PromiseKit

internal extension Promise {
    
    func retryingIfNeeded(on queue: DispatchQueue = SnodeAPI.workQueue, maxRetryCount: UInt) -> Promise<T> {
        var retryCount = 0
        func retryIfNeeded() -> Promise<T> {
            return recover(on: queue) { error -> Promise<T> in
                guard retryCount != maxRetryCount else { throw error }
                retryCount += 1
                return retryIfNeeded()
            }
        }
        return retryIfNeeded()
    }
}
