import AppKit
import Testing
import Foundation
@testable import MeetGPT

/// The top inset is a contract with history, because it has flip-flopped:
/// 30 once collided the sidebar brand with the traffic lights, the
/// short-window fix raised it to 52, and the owner then unified sidebar and
/// content panes at 16 after checking the real window (the brand row clears
/// the lights horizontally). Changing this number again should be a decision
/// that reads that history, not a drive-by.
@Suite("Layout inset contract")
struct LayoutInsetContractTests {
    @Test("one shared inset, owner-set to 16")
    func unifiedInset() {
        #expect(kContentTopInset == 16)
    }

    /// Боковая колонка держит ширину, выбранную под макет.
    ///
    /// Здесь была ошибка диагноза, и она стоила двух заходов. Сначала я решил,
    /// что виновата жёсткая ширина: `.frame(width: 264)` центрирует
    /// содержимое, и текст обрезался с обеих сторон. Сделал ширину гибкой —
    /// обрезание перешло на другую сторону, а колонка вдобавок просела до
    /// минимума и сломала ряд «Добавить · Наборы».
    ///
    /// Причина была в другом: вертикальный ScrollView не навязывает ширину
    /// содержимому (см. `sidebarContentAdoptsPanelWidth`). Ширина вернулась к
    /// 264, а выравнивание осталось — на случай, если содержимое когда-нибудь
    /// всё же окажется шире: пусть режет хвост, а не начало.
    @Test("боковая колонка держит ширину макета")
    func panesCanShrink() {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetGPT/Views/ContentView.swift")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        #expect(!text.isEmpty, "не прочитался ContentView.swift")

        // Комментарии пропускаются: в них старое значение приведено нарочно.
        let code = text.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        // Ширина снова 264, и это осознанный возврат: гибкая ширина лечила
        // симптом и стоила своего — колонка проседала до минимума (панель
        // ассистента с idealWidth 392 перетягивала), и в 216 уже не помещался
        // ряд «Добавить · Наборы». Настоящая причина обрезания была в
        // ScrollView, и она чинится в Sidebar.
        #expect(code.contains(".frame(width: 264, alignment: .leading)"),
                "у боковой панели уехала ширина, выбранная под макет")
        #expect(code.contains("alignment: .leading"),
                "без выравнивания по левому краю обрезаться снова будет начало строки, а не хвост")
    }

    /// Содержимое боковой панели обязано брать ширину у панели.
    ///
    /// Вертикальный ScrollView не навязывает детям свою ширину: Text получает
    /// «идеальную» — всю строку без переносов, — и столбец становится шире
    /// панели. Текст тогда обрезается, и сторона обрезки зависит только от
    /// выравнивания: сначала пропадало начало строк («АСТРОЙКА»), после
    /// `alignment: .leading` — концы («оставь» вместо «оставьте»).
    ///
    /// Проверяются оба признака, потому что каждый по отдельности уже
    /// подводил: `.frame(maxWidth: .infinity)` выглядит как ограничение, но
    /// «бесконечность» здесь означает «сколько хочешь», и текст всё равно не
    /// переносился. Ширину должен давать GeometryReader, и вычитание отступов
    /// обязано быть в формуле — без него содержимое ровно на 2×16 шире панели.
    @Test("столбец боковой панели берёт ширину у панели, а не у текста")
    func sidebarContentAdoptsPanelWidth() {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetGPT/Views/Sidebar.swift")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        #expect(!text.isEmpty, "не прочитался Sidebar.swift")

        let code = text.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        #expect(code.contains("GeometryReader"),
                "ширина снова берётся не у панели — текст перестанет переноситься")
        #expect(code.contains("geometry.size.width - 2 * Space.l"),
                "из ширины панели не вычитаются отступы — столбец будет шире неё")
        // Зашитое число разъедется с панелью, которая умеет сужаться до 216.
        #expect(!code.contains(".frame(width: 232"),
                "ширина столбца зашита числом — при узком окне снова обрежет")
    }

    /// То же самое для панели ответа — там форма была ровно та же.
    ///
    /// Панель ассистента уже боковой (340–460), а текста в ней больше: это
    /// ответ модели. Стоял тот же `.frame(maxWidth: .infinity)`, который в
    /// боковой панели ничего не ограничивал.
    ///
    /// Честно: живьём я это обрезание не воспроизвёл — без ключа провайдера
    /// ответа на экране нет. Правка сделана по совпадению формы, а не по
    /// увиденной поломке, и проверка здесь удерживает именно форму.
    @Test("панель ответа берёт ширину у себя, а не у текста")
    func answerPaneAdoptsPaneWidth() {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetGPT/Views/AIResponseView.swift")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        #expect(!text.isEmpty, "не прочитался AIResponseView.swift")

        let code = text.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        #expect(code.contains("GeometryReader"),
                "ширина ответа снова берётся у текста")
        #expect(code.contains("geometry.size.width - 2 * Space.l"),
                "из ширины панели ответа не вычитаются отступы")
    }

    /// Ряд «Добавить · Наборы» обязан помещаться в колонку.
    ///
    /// Он не помещался, и по-английски это было незаметно: «Add source» +
    /// «Sets» укладывались, «Добавить источник» + «Наборы» дают 250 pt при 232
    /// доступных. У «Наборов» стоит `.fixedSize()` — сжиматься нельзя, — и
    /// подпись вылезала за собственную иконку.
    ///
    /// Меряется тем же способом, что и заголовки: системный шрифт 13 pt плюс
    /// иконка, промежуток и горизонтальные отступы кнопки.
    @Test("ряд «Добавить · Наборы» помещается в боковую панель")
    func contextRowFitsTheSidebar() {
        let available: CGFloat = 264 - 2 * 16          // ширина панели минус отступы
        let font = NSFont.systemFont(ofSize: 13)
        // Иконка 14 + промежуток 5 + отступы кнопки 16 — то, что кнопка
        // занимает сверх самой подписи.
        let chrome: CGFloat = 35

        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetGPT/Views/ContextPanel.swift")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        #expect(!text.isEmpty, "не прочитался ContextPanel.swift")

        // Подписи берутся из кода, а не переписываются сюда: переписанная
        // копия разъедется с кнопкой, и проверка станет фиктивной.
        let labels = text.components(separatedBy: #"Label(""#).dropFirst()
            .compactMap { chunk in chunk.firstIndex(of: "\"").map { String(chunk[..<$0]) } }
        guard let addTitle = labels.first(where: { $0.hasPrefix("Добавить") }),
              let setsTitle = labels.first(where: { $0 == "Наборы" }) else {
            Issue.record("подписи ряда не нашлись — проверка была бы фиктивной")
            return
        }

        let width = (addTitle as NSString).size(withAttributes: [.font: font]).width + chrome
            + (setsTitle as NSString).size(withAttributes: [.font: font]).width + chrome
            + 8                                        // промежуток между кнопками
        #expect(width <= available,
                "«\(addTitle)» + «\(setsTitle)» — \(Int(width)) pt при \(Int(available)) доступных")
    }

    /// Ни один заголовок раздела не должен просить больше, чем есть в панели.
    ///
    /// Проверка появилась после поломки, которую не видит ни один текстовый
    /// тест. У боковой панели жёсткая ширина 264, а `.frame(width:)` центрирует
    /// содержимое: заголовок «До понедельника звонков нет?» (233 pt в верхнем
    /// регистре при 212 доступных) раздвинул столбец, и тот вылез за ОБА края
    /// панели. В итоге у каждой строки пропала первая буква — «АСТРОЙКА»,
    /// «о-пилот», «адайте цель». Английский оригинал занимал 171 pt и
    /// помещался — под него ширину 264 когда-то и выбрали.
    ///
    /// Замер повторяет то, что делает SwiftUI: `Typo.label` — системный шрифт
    /// 11 pt semibold, плюс трекинг 0.9 на символ.
    @Test("заголовки разделов помещаются в боковую панель")
    func sectionLabelsFitTheSidebar() {
        // 264 — ширина панели, 2×16 — горизонтальные отступы содержимого,
        // 20 — крестик «скрыть» с промежутком в самых тесных заголовках.
        let available: CGFloat = 264 - 2 * 16 - 20
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)

        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetGPT/Views")
        guard let walker = FileManager.default.enumerator(atPath: views.path) else {
            Issue.record("не открылась папка Views — проверка была бы фиктивной")
            return
        }

        var checked = 0
        for case let entry as String in walker where entry.hasSuffix(".swift") {
            let text = (try? String(contentsOf: views.appendingPathComponent(entry),
                                    encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n")
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                guard let start = line.range(of: "SectionLabel(\""),
                      let end = line[start.upperBound...].firstIndex(of: "\"") else { continue }
                let label = String(line[start.upperBound..<end])
                // Строки со вставками не меряются — их длина плавает.
                guard !label.contains("\\(") else { continue }

                let upper = label.uppercased()
                let width = (upper as NSString).size(withAttributes: [.font: font]).width
                    + CGFloat(upper.count) * 0.9
                checked += 1
                #expect(width <= available,
                        "«\(upper)» — \(Int(width)) pt при \(Int(available)) доступных (\(entry))")
            }
        }
        #expect(checked >= 8, "нашлось всего \(checked) заголовков — проверка почти пустая")
    }
}
