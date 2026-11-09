import SwiftUI
import PencilKit
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: Page assistant and maths help

/// Reads the current page on the device (handwriting, typed text and PDF text) and answers questions
/// about it with Apple's on-device language model. Nothing leaves the iPad.
@MainActor final class PageAssistant: ObservableObject {
    @Published var question = ""
    @Published var answer = ""
    @Published var pageText = ""
    @Published var busy = false
    @Published var status = ""

    static var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { if case .available = SystemLanguageModel.default.availability { return true } }
        #endif
        return false
    }

    func read(page: NotebookPage, directory: URL) async {
        status = "Seite wird gelesen …"
        let text = await Task.detached(priority: .userInitiated) { () -> String in
            var parts: [String] = []
            if let image = try? NotebookThumbnail.render(page: page, directory: directory, width: 1600), let cg = image.cgImage {
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
                request.recognitionLanguages = ["de-DE", "en-US"]
                try? VNImageRequestHandler(cgImage: cg).perform([request])
                parts += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            }
            return parts.joined(separator: "\n")
        }.value
        pageText = text
        status = text.isEmpty ? "Auf dieser Seite wurde kein Text erkannt." : "\(text.split(separator: "\n").count) Zeilen erkannt."
    }

    func ask(math: Bool) async {
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || math else { return }
        busy = true; defer { busy = false }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), Self.modelAvailable {
            let instructions = math
                ? "Du bist eine Mathe-Assistenz für Schüler. Prüfe die Rechnungen auf der Seite Schritt für Schritt, nenne Fehler und die richtige Lösung. Antworte auf Deutsch und knapp."
                : "Du hilfst beim Lernen mit handschriftlichen Notizen. Antworte auf Deutsch, knapp und nur auf Grundlage der Seite, wenn die Frage sich darauf bezieht."
            let session = LanguageModelSession(instructions: instructions)
            do {
                let request = "Text der Seite (automatisch erkannt, kann Fehler enthalten):\n\(pageText.prefix(6000))\n\n" + (prompt.isEmpty ? "Prüfe die Mathematik auf dieser Seite." : "Frage: \(prompt)")
                answer = try await session.respond(to: request).content
            } catch { answer = "Die Antwort konnte nicht erzeugt werden: \(error.localizedDescription)" }
            return
        }
        #endif
        answer = "Apple Intelligence ist auf diesem iPad nicht verfügbar oder nicht eingeschaltet (Einstellungen → Apple Intelligence & Siri). Der erkannte Text der Seite steht oben und lässt sich kopieren."
    }
}

@MainActor struct AssistantPanel: View {
    let page: NotebookPage?
    let directory: URL
    var math = false
    @StateObject private var assistant = PageAssistant()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: math ? "function" : "sparkles").foregroundStyle(Theme.accent)
                Text(math ? "Prüft Rechnungen auf dieser Seite." : "Fragen zu dieser Seite stellen.").font(.subheadline)
                Spacer()
                if assistant.busy { ProgressView() }
            }
            Text(assistant.status).font(.caption).foregroundStyle(Theme.secondary)
            if !assistant.pageText.isEmpty {
                ScrollView { Text(assistant.pageText).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 160).padding(10).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 10))
            }
            if !math {
                HStack {
                    TextField("Frage eingeben", text: $assistant.question).textFieldStyle(.roundedBorder).onSubmit { Task { await assistant.ask(math: false) } }
                    Button("Fragen") { Task { await assistant.ask(math: false) } }.buttonStyle(.borderedProminent).disabled(assistant.busy || assistant.question.isEmpty)
                }
            } else {
                Button { Task { await assistant.ask(math: true) } } label: { Label("Seite prüfen", systemImage: "checkmark.seal") }.buttonStyle(.borderedProminent).disabled(assistant.busy)
            }
            ScrollView { Text(assistant.answer).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            Spacer(minLength: 0)
        }.padding(20)
            .task { if let page { await assistant.read(page: page, directory: directory) } }
    }
}

// MARK: Writing aids

struct WritingAidsView: View {
    @Binding var settings: ToolSettings
    var body: some View {
        VStack(spacing: 0) {
            Text("Schreibhilfen").font(.system(size: 15, weight: .semibold)).frame(height: 44)
            Form {
                Section {
                    Toggle("Zum Formen halten", isOn: $settings.holdForShapes)
                    Toggle("Stärke nach Geschwindigkeit", isOn: $settings.reactToSpeed)
                    Toggle("Textmarker gerade ziehen", isOn: $settings.straightHighlighter)
                } footer: { Text("Halte den Stift am Ende eines Strichs kurz still, um eine saubere Form oder Linie zu erhalten.") }
                Section("Glättung") {
                    VStack(alignment: .leading) { Text("Stift").font(.caption); Slider(value: $settings.stabilization, in: 0 ... 1) }
                    VStack(alignment: .leading) { Text("Textmarker").font(.caption); Slider(value: $settings.highlighterStabilization, in: 0 ... 1) }
                }
                Section("Klebeband") {
                    HStack(spacing: 12) {
                        ForEach(["#E9B949", "#F28B82", "#81C995", "#8AB4F8", "#C58AF9", "#BDBBB5"], id: \.self) { color in
                            Button { settings.tapeColor = color } label: { Circle().fill(Color(hex: color)).frame(width: 26, height: 26).overlay { Circle().stroke(settings.tapeColor == color ? Theme.accent : .clear, lineWidth: 2).padding(-3) } }.buttonStyle(.solidPlain)
                        }
                    }
                }
            }.scrollContentBackground(.hidden)
        }.frame(width: 340, height: 470).background(Theme.popover).presentationBackground(Theme.popover)
    }
}

// MARK: Timer

@MainActor final class StudyTimer: ObservableObject {
    @Published var remaining: TimeInterval = 25 * 60
    @Published var running = false
    @Published var visible = false
    private var end: Date?
    private var ticker: Timer?
    func start(minutes: Double? = nil) {
        if let minutes { remaining = minutes * 60 }
        end = Date().addingTimeInterval(remaining); running = true; visible = true
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let end = self.end else { return }
                self.remaining = max(0, end.timeIntervalSinceNow)
                if self.remaining == 0 { self.pause(); UINotificationFeedbackGenerator().notificationOccurred(.success) }
            }
        }
    }
    func pause() { running = false; ticker?.invalidate(); ticker = nil }
    func close() { pause(); visible = false }
    var label: String { String(format: "%02d:%02d", Int(remaining) / 60, Int(remaining) % 60) }
}

struct StudyTimerPill: View {
    @ObservedObject var timer: StudyTimer
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "timer").foregroundStyle(timer.remaining == 0 ? .red : Theme.accent)
            Text(timer.label).font(.system(size: 17, weight: .semibold).monospacedDigit())
            Menu { ForEach([5.0, 10, 15, 25, 45, 60, 90], id: \.self) { m in Button("\(Int(m)) Minuten") { timer.start(minutes: m) } } } label: { Image(systemName: "clock.arrow.circlepath") }
            Button { timer.running ? timer.pause() : timer.start() } label: { Image(systemName: timer.running ? "pause.fill" : "play.fill") }
            Button { timer.close() } label: { Image(systemName: "xmark") }
        }.foregroundStyle(.white).padding(.horizontal, 16).frame(height: 44).background(Theme.pill, in: Capsule()).overlay { Capsule().stroke(.white.opacity(0.1)) }
            .buttonStyle(.solidPlain).transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

// MARK: Flashcards

/// A study set is a notebook whose pages come in pairs: front, then back. Studying shows one card at a
/// time and flips it with a tap; swiping moves on.
@MainActor struct FlashcardStudyView: View {
    let item: LibraryItem
    let directory: URL
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var flipped = false
    private var cards: [(NotebookPage, NotebookPage?)] {
        stride(from: 0, to: item.pages.count, by: 2).map { (item.pages[$0], $0 + 1 < item.pages.count ? item.pages[$0 + 1] : nil) }
    }
    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Button("Fertig") { dismiss() }
                Spacer(); Text(cards.isEmpty ? "Keine Karten" : "Karte \(index + 1) von \(cards.count)").font(.headline); Spacer()
                Button { flipped = false; index = 0 } label: { Image(systemName: "arrow.counterclockwise") }
            }.padding(.horizontal, 20).padding(.top, 16)
            if cards.indices.contains(index) {
                let card = cards[index]
                ZStack {
                    NotebookPreview(page: card.0, directory: directory).opacity(flipped ? 0 : 1)
                    if let back = card.1 { NotebookPreview(page: back, directory: directory).opacity(flipped ? 1 : 0).rotation3DEffect(.degrees(180), axis: (0, 1, 0)) }
                }
                .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (0, 1, 0), perspective: 0.4)
                .padding(.horizontal, 40).frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { flipped.toggle() } }
                .gesture(DragGesture(minimumDistance: 40).onEnded { value in
                    let next = value.translation.width < 0 ? index + 1 : index - 1
                    guard cards.indices.contains(next) else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { flipped = false; index = next }
                })
                Text(flipped ? "Rückseite – wischen für die nächste Karte" : "Vorderseite – tippen zum Umdrehen").font(.footnote).foregroundStyle(Theme.secondary).padding(.bottom, 24)
            } else { Spacer() }
        }.foregroundStyle(.white).background(Theme.library.ignoresSafeArea())
    }
}

enum StudyDocuments {
    /// Front/back pairs with a label on each page, in landscape A5 like index cards.
    @MainActor static func createFlashcards(store: LibraryStore, parent: String?) -> LibraryItem? {
        guard var item = store.add(title: "Lernset", parent: parent, color: "#FFFFFF") else { return nil }
        item.kind = .flashcards
        item.pages = (0 ..< 10).map { i in var p = NotebookPage(); p.width = 595; p.height = 420; p.paper = "blank"; return p }
        for (i, page) in item.pages.enumerated() {
            let label = TextBox(text: i % 2 == 0 ? "Vorderseite \(i / 2 + 1)" : "Rückseite \(i / 2 + 1)", x: 16, y: 10, width: 220, height: 30, fontSize: 12)
            try? JSONEncoder().encode([label]).write(to: store.directory(item.id).appendingPathComponent(page.id + ".texts.json"), options: .atomic)
        }
        if let cover = NotebookCover.make(color: "#2E4A7D") { try? cover.write(to: NotebookCover.url(store.directory(item.id)), options: .atomic) }
        store.update(item); return item
    }
    /// A typed document: one blank page holding a page-wide text box ready for the keyboard.
    @MainActor static func createTextDocument(store: LibraryStore, parent: String?) -> LibraryItem? {
        guard var item = store.add(title: "Unbenanntes Textdokument", parent: parent, color: "#FFFFFF") else { return nil }
        item.pages[0].paper = "blank"
        let box = TextBox(text: "", x: 48, y: 56, width: item.pages[0].width - 96, height: item.pages[0].height - 112, fontSize: 17)
        try? JSONEncoder().encode([box]).write(to: store.directory(item.id).appendingPathComponent(item.pages[0].id + ".texts.json"), options: .atomic)
        store.update(item); return item
    }
}
