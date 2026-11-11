import Combine
import PencilKit
import SwiftUI
import UIKit

/// Voice or typed request -> gateway on the server (over Tailscale) -> answer streamed back and written
/// onto the page as ink below the last line, word by word. One undo removes the whole answer.
@MainActor final class NoteAgentController: ObservableObject {
    enum Phase: Equatable { case idle, loadingModel, listening, transcribing, waiting, writing }

    @Published private(set) var phase: Phase = .idle
    @Published var typed = ""
    @Published private(set) var transcript = ""
    @Published private(set) var answer = ""
    @Published private(set) var route = ""
    @Published private(set) var message = ""
    @Published private(set) var level: Float = 0
    @Published var attachPage = false
    @Published var useTrainedHandwriting = true

    let socket = TailscaleAgentSocket()
    private let whisper = M3WhisperTranscriber()
    private var job: Task<Void, Never>?
    private var socketChanges: AnyCancellable?

    init() {
        // The view observes this controller only; pass the socket's state changes through.
        socketChanges = socket.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var busy: Bool { phase != .idle }

    func talk(commands: CanvasCommands, page: NotebookPage, directory: URL, pageText: String) {
        guard !busy else { return }
        message = ""
        job = Task {
            do {
                let text = try await whisper.listenOnce(
                    onPhase: { phase in Task { @MainActor [weak self] in self?.phase = Self.map(phase) } },
                    onLevel: { level in Task { @MainActor [weak self] in self?.level = level } })
                level = 0
                guard !Task.isCancelled else { phase = .idle; return }
                guard !text.isEmpty else { message = "Nichts verstanden. Sprich nach dem Tippen auf das Mikrofon."; phase = .idle; return }
                transcript = text
                await ask(text, commands: commands, page: page, directory: directory, pageText: pageText)
            } catch {
                message = error.localizedDescription; phase = .idle; level = 0
            }
        }
    }

    func send(commands: CanvasCommands, page: NotebookPage, directory: URL, pageText: String) {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !text.isEmpty else { return }
        transcript = text; typed = ""; message = ""
        job = Task { await ask(text, commands: commands, page: page, directory: directory, pageText: pageText) }
    }

    /// Ends listening early (the recording so far is transcribed and sent).
    func stopListening() { Task { await whisper.stop() } }

    func cancel() {
        job?.cancel(); job = nil
        Task { await whisper.stop() }
        phase = .idle; level = 0
    }

    private static func map(_ phase: M3WhisperTranscriber.Phase) -> Phase {
        switch phase { case .loadingModel: return .loadingModel; case .listening: return .listening; case .transcribing: return .transcribing }
    }

    private func ask(_ text: String, commands: CanvasCommands, page: NotebookPage, directory: URL, pageText: String) async {
        commands.flush()
        let drawing = commands.snapshot()
        let size = page.size
        let style = SynthInkStyle.matching(drawing)
        let anchor = PKStrokeSynthesizer.anchor(below: drawing, pageSize: size, style: style)
        let profile = useTrainedHandwriting ? HandwritingLibrary(directory: directory).profile : nil
        let writer = PKStrokeSynthesizer(anchor: anchor, pageSize: size, style: style, profile: profile)
        let request = AgentRequest(transcript: text,
                                   canvasImageBase64: attachPage ? Self.pageImage(drawing, size: size) : nil,
                                   cursor: anchor, pageText: String(pageText.prefix(8000)))
        phase = .waiting; answer = ""; route = ""
        var firstInk = true
        func put(_ strokes: [PKStroke]) {
            guard !strokes.isEmpty else { return }
            commands.appendStreaming(strokes, startsUndoGroup: firstInk); firstInk = false
        }
        do {
            for try await event in socket.send(request) {
                switch event {
                case .status(let status): message = status
                case .route(let r, let backend, _, let ms):
                    route = "\(r) · \(backend)" + (ms > 0 ? " · Triage \(ms) ms" : ""); phase = .writing; message = ""
                case .token(let token): answer += token; put(writer.write(token))
                case .done: put(writer.finish())
                case .failed(let failure): message = failure
                }
            }
            if writer.overflowed { message = "Die Seite ist voll. Der Rest der Antwort steht nur hier im Panel." }
        } catch is CancellationError {
            put(writer.finish())
        } catch {
            put(writer.finish()); message = error.localizedDescription
        }
        phase = .idle
    }

    /// The page's ink on white as a JPEG data URL (PDF backgrounds are not included).
    static func pageImage(_ drawing: PKDrawing, size: CGSize) -> String? {
        let rect = CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1.5; return f }())
        let image = renderer.image { context in
            UIColor.white.setFill(); context.fill(rect)
            drawing.image(from: rect, scale: 1.5).draw(in: rect)
        }
        return image.jpegData(compressionQuality: 0.7).map { "data:image/jpeg;base64," + $0.base64EncodedString() }
    }
}

@MainActor struct NoteAgentSection: View {
    let commands: CanvasCommands
    let page: NotebookPage
    let directory: URL
    let pageText: String
    @StateObject private var agent = NoteAgentController()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(connectionColor).frame(width: 8, height: 8)
                Text("Notiz-Agent").font(.headline)
                Text(connectionText).font(.caption).foregroundStyle(Theme.secondary)
                Spacer()
                if agent.busy { Button("Abbrechen", role: .cancel) { agent.cancel() }.font(.caption) }
            }
            HStack(spacing: 12) {
                Button { micTapped() } label: {
                    Image(systemName: agent.phase == .listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(agent.phase == .listening ? Color.red : Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(agent.busy && agent.phase != .listening)
                .accessibilityLabel(agent.phase == .listening ? "Aufnahme beenden" : "Frage sprechen")
                VStack(alignment: .leading, spacing: 4) {
                    Text(phaseText).font(.subheadline)
                    if agent.phase == .listening {
                        GeometryReader { geo in Capsule().fill(Theme.accent).frame(width: max(4, geo.size.width * CGFloat(agent.level))) }.frame(height: 4)
                    }
                }
            }
            HStack {
                TextField("Oder Anfrage tippen", text: $agent.typed).textFieldStyle(.roundedBorder)
                    .onSubmit { agent.send(commands: commands, page: page, directory: directory, pageText: pageText) }
                Button("Senden") { agent.send(commands: commands, page: page, directory: directory, pageText: pageText) }
                    .disabled(agent.busy || agent.typed.isEmpty)
            }
            Toggle("Seite als Bild mitsenden (Skizzen, Formeln)", isOn: $agent.attachPage).font(.footnote)
            Toggle("In meiner trainierten Handschrift schreiben", isOn: $agent.useTrainedHandwriting).font(.footnote)
            if !agent.transcript.isEmpty { Text("„\(agent.transcript)“").font(.footnote).italic() }
            if !agent.route.isEmpty { Text(agent.route).font(.caption2).foregroundStyle(Theme.secondary) }
            if !agent.message.isEmpty { Text(agent.message).font(.caption).foregroundStyle(.orange) }
            if !agent.answer.isEmpty {
                ScrollView { Text(agent.answer).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 140)
            }
        }
        .padding(12).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 10))
        .onAppear { agent.socket.connect() }
        .onDisappear { agent.cancel(); agent.socket.disconnect() }
    }

    private func micTapped() {
        if agent.phase == .listening { agent.stopListening() }
        else { agent.talk(commands: commands, page: page, directory: directory, pageText: pageText) }
    }

    private var phaseText: String {
        switch agent.phase {
        case .idle: return "Tippen und sprechen – die Antwort erscheint als Tinte unter deiner letzten Zeile."
        case .loadingModel: return "Spracherkennung wird geladen (beim ersten Mal ca. 470 MB) …"
        case .listening: return "Ich höre zu … (endet nach einer kurzen Pause)"
        case .transcribing: return "Wird transkribiert …"
        case .waiting: return "Warte auf den Server …"
        case .writing: return "Schreibt auf die Seite …"
        }
    }
    private var connectionText: String {
        switch agent.socket.state {
        case .idle: return "getrennt"
        case .connecting: return "verbindet …"
        case .connected: return "verbunden"
        case .waiting(let s): return "neuer Versuch in \(s) s"
        case .failed(let m): return m
        }
    }
    private var connectionColor: Color {
        switch agent.socket.state {
        case .connected: return .green
        case .connecting, .waiting: return .orange
        case .failed: return .red
        case .idle: return .gray
        }
    }
}
