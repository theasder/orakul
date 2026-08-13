import SwiftUI
import OrakulCore

/// Окно orakul: три вещи и ничего больше — записать, найти, прочитать ответ.
///
/// Интерфейс намеренно тонкий. Всё, что решает, ЧТО показать, живёт в
/// `OrakulCore` и покрыто тестами; здесь только кнопки и текст, потому что
/// проверить SwiftUI-разметку тестом дорого, а сломать её незаметно — легко.
@main
struct OrakulApp: App {
    var body: some Scene {
        WindowGroup("orakul") {
            ContentView()
                .frame(minWidth: 620, minHeight: 460)
        }
    }
}

@MainActor
final class ArchiveModel: ObservableObject {
    @Published var question = ""
    @Published var answer = ""
    @Published var status = ""
    @Published var sessions: [RecallIndex.Session] = []

    private let store: SessionStore

    init() {
        let home = ProcessInfo.processInfo.environment["ORAKUL_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".orakul").path
        store = SessionStore(root: URL(fileURLWithPath: home))
        reload()
    }

    /// Разобранный архив. Строится один раз на загрузку, а не на каждый вопрос.
    ///
    /// `RecallIndex` разбирает слова всех встреч при создании. Пока индекс
    /// создавался прямо в `search()`, месяц часовых звонков разбирался заново
    /// на каждое нажатие «Найти» — секунды ожидания каждый раз, а не только
    /// первый.
    private var index: RecallIndex?

    func reload() {
        let archive = store.load()
        sessions = archive.sessions
        index = nil            // архив изменился — старый разбор недействителен
        // Пропущенные файлы показываются, а не проглатываются: тихо потерянная
        // встреча — худший исход для архива.
        status = archive.skipped.isEmpty
            ? ""
            : "Не смог прочитать: \(archive.skipped.joined(separator: ", "))"
    }

    func search() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Тот же составитель ответа, что и в командной строке: двух форматов
        // «ответа» у продукта быть не должно.
        let index = self.index ?? RecallIndex(sessions: sessions)
        self.index = index
        answer = RecallAnswer.compose(query: trimmed, hits: index.search(trimmed),
                                      archiveIsEmpty: sessions.isEmpty)
    }
}

struct ContentView: View {
    @StateObject private var model = ArchiveModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("orakul")
                .font(.system(size: 22, weight: .semibold, design: .serif))

            HStack(spacing: 8) {
                TextField("Что мы решили по тарифам?", text: $model.question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.search() }
                Button("Найти") { model.search() }
                    .keyboardShortcut(.defaultAction)
            }

            if !model.answer.isEmpty {
                ScrollView {
                    Text(model.answer)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }

            Divider()

            HStack {
                Text("Созвоны: \(model.sessions.count)").foregroundStyle(.secondary)
                Spacer()
                Button("Обновить") { model.reload() }
            }
            .font(.system(size: 12))

            List(model.sessions, id: \.id) { session in
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                    Text(session.date).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 140)

            if !model.status.isEmpty {
                Text(model.status).font(.system(size: 11)).foregroundStyle(.orange)
            }

            // Запись пока делает командная строка: в окне у неё нет ни выбора
            // устройства, ни индикатора уровня, а кнопка без них обманывает.
            Text("Запись: orakul записать 60 «Планёрка». Системный звук пока не пишется — "
                 + "только ваш микрофон.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}
