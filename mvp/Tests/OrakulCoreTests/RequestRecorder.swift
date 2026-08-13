import Foundation

/// Что коннектор отправил в сеть. Лежал тремя одинаковыми копиями в наборах
/// про российские трекеры, свои серверы и мессенджеры; четвёртая копия
/// понадобилась для заведения задач — и стало ясно, что копий уже слишком
/// много, чтобы правка задевала одну.
///
/// `@unchecked Sendable` с замком, а не актор: коннекторы зовут запись из
/// своей задачи, и `await` внутри стаба переставил бы порядок, который тесты
/// как раз и проверяют.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
    }
    var last: URLRequest? { lock.lock(); defer { lock.unlock() }; return requests.last }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}
