import SwiftUI
import Speech
import AVFoundation

@MainActor final class ClassroomRecorder:ObservableObject {
    @Published var running = false
    @Published var transcript = ""
    @Published var message = ""
    private let engine = AVAudioEngine()
    private var task:SFSpeechRecognitionTask?
    private var request:SFSpeechAudioBufferRecognitionRequest?
    private var tapped = false
    private var starting = false
    private var generation = UUID()
    func start() async {
        guard !running, !starting else { return }
        starting = true; let generation = self.generation
        defer { starting = false }
        let speech = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning:$0) } }
        let mic = await withCheckedContinuation { continuation in AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning:$0) } }
        guard generation == self.generation else { return }
        guard speech == .authorized, mic else { message = "Mikrofon- und Spracherkennungszugriff werden benötigt."; return }
        guard let recognizer = SFSpeechRecognizer(locale:Locale(identifier:"de-DE")), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { message = "Lokale deutsche Spracherkennung ist auf diesem Gerät nicht verfügbar."; return }
        do {
            let session = AVAudioSession.sharedInstance(); try session.setCategory(.record,mode:.measurement,options:.duckOthers); try session.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest(); request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true; self.request = request
            let input = engine.inputNode; let format = input.outputFormat(forBus:0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw NotebookError.invalid("Kein verfügbares Mikrofon.") }
            input.installTap(onBus:0,bufferSize:1024,format:format) { buffer,_ in request.append(buffer) }; tapped = true
            task = recognizer.recognitionTask(with:request) { [weak self] result,error in
                Task { @MainActor in
                    guard let self, generation == self.generation else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if error != nil || result?.isFinal == true { self.stop(); if let error { self.message = error.localizedDescription } }
                }
            }
            engine.prepare(); try engine.start(); running = true; message = "Aufnahme läuft lokal."
        } catch { stop(); message = error.localizedDescription }
    }
    func stop() {
        generation = UUID(); starting = false
        engine.stop(); if tapped { engine.inputNode.removeTap(onBus:0); tapped = false }
        request?.endAudio(); task?.cancel(); task = nil; request = nil; running = false
        try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
    }
}
@MainActor struct ListenerView:View {
    @StateObject private var recorder = ClassroomRecorder()
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack { Circle().fill(recorder.running ? .red : .gray).frame(width:10,height:10); Text(recorder.running ? "Aufnahme aktiv" : "Mikrofon aus").font(.headline); Spacer(); Button(recorder.running ? "Stoppen" : "Aufnahme starten") { if recorder.running { recorder.stop() } else { Task { await recorder.start() } } }.buttonStyle(.borderedProminent) }
            Text("Die Aufnahme startet nur hier und endet beim Schließen dieser Ansicht. Die Transkription bleibt auf deinem Gerät.").font(.subheadline).foregroundStyle(.secondary)
            TextEditor(text:$recorder.transcript).scrollContentBackground(.hidden).padding(8).background(Theme.sidebar,in:RoundedRectangle(cornerRadius:10)).overlay { RoundedRectangle(cornerRadius:10).stroke(Theme.border) }
            HStack { Text(recorder.message).font(.footnote).foregroundStyle(.secondary); Spacer(); ShareLink(item:recorder.transcript) { Label("Text teilen",systemImage:"square.and.arrow.up") }.disabled(recorder.transcript.isEmpty) }
        }.padding(24).goodnotesSheet().onDisappear { recorder.stop() }
    }
}
