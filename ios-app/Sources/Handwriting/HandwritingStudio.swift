import SwiftUI
import PencilKit
import UIKit

struct HandwritingProfile: Codable {
    var glyphs: [String:[Data]] = [:]
    var size: Double = 28
    var wordSpacing: Double = 12
    var lineSpacing: Double = 16
    var irregularity: Double = 0.08
    var margin: Double = 48
    var color = "#1E1B1B"
}

@MainActor final class HandwritingLibrary: ObservableObject {
    @Published var profile = HandwritingProfile()
    @Published var message = ""
    private let url: URL
    private var writable = true
    static let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789äöüßÄÖÜ.,!?;:-+=()")
    init(directory:URL) {
        url = directory.appendingPathComponent("handwriting-profile.json")
        if FileManager.default.fileExists(atPath:url.path) {
            do { profile = try JSONDecoder().decode(HandwritingProfile.self,from:Data(contentsOf:url)) }
            catch { writable = false; message = "Schriftprofil konnte nicht gelesen werden: \(error.localizedDescription)" }
        }
    }
    func save() throws { guard writable else { throw NotebookError.invalid("Das beschädigte Schriftprofil wird nicht überschrieben.") }; try JSONEncoder().encode(profile).write(to:url,options:.atomic) }
    func train(_ character:Character,drawing:PKDrawing) throws {
        guard writable else { throw NotebookError.invalid("Das gespeicherte Schriftprofil muss zuerst wiederhergestellt werden.") }
        guard !drawing.strokes.isEmpty, drawing.bounds.width > 0, drawing.bounds.height > 0 else { throw NotebookError.invalid("Schreibe zuerst das Zeichen in das Übungsfeld.") }
        let key = String(character)
        guard (profile.glyphs[key]?.count ?? 0) < 12 else { throw NotebookError.invalid("Für dieses Zeichen sind bereits zwölf Varianten gespeichert.") }
        let before = profile; profile.glyphs[key,default:[]].append(drawing.dataRepresentation())
        do { try save() } catch { profile = before; throw error }
        message = "Variante für „\(character)“ gespeichert."
    }
    func analyze(_ drawing:PKDrawing, original:OriginalInk) {
        let bounds = drawing.strokes.map { $0.renderBounds } + original.strokes.map { $0.path.boundingBoxOfPath }
        let heights = bounds.map(\.height).filter { $0 > 5 && $0 < 200 }.sorted()
        let widths = drawing.strokes.flatMap { $0.path.map { $0.size.width } } + original.strokes.map(\.width)
        let sortedWidths = widths.filter { $0 > 0 }.sorted()
        if !heights.isEmpty { profile.size = min(80,max(8,Double(heights[heights.count/2]))) }
        let ys = bounds.map(\.midY).sorted(); var rows: [CGFloat] = []
        for y in ys { if let last = rows.last, abs(y-last) < CGFloat(profile.size)*0.7 { rows[rows.count-1] = (last+y)/2 } else { rows.append(y) } }
        let distances = zip(rows,rows.dropFirst()).map { $1-$0 }.sorted()
        if !distances.isEmpty { profile.lineSpacing = max(0,Double(distances[distances.count/2])-profile.size) }
        if let first = bounds.map(\.minX).filter({$0 >= 0}).min() { profile.margin = min(150,max(8,Double(first))) }
        let color = drawing.strokes.first?.ink.color ?? original.strokes.first?.color
        if let color {
            var r:CGFloat = 0,g:CGFloat = 0,b:CGFloat = 0,a:CGFloat = 0
            if color.getRed(&r,green:&g,blue:&b,alpha:&a) { profile.color = String(format:"#%02X%02X%02X",Int(r*255),Int(g*255),Int(b*255)) }
        }
        let thick = sortedWidths.isEmpty ? "–" : String(format:"%.2f",Double(sortedWidths[sortedWidths.count/2]))
        message = "Geometrische Schätzung: \(Int(profile.size)) pt Höhe, \(thick) pt Strichbreite, \(rows.count) Zeilengruppen. Zeichenformen stammen aus deinem Training."
    }
    func synthesize(_ text:String,page:CGSize,seed:UInt64 = 42) throws -> [PKStroke] {
        let text = text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
        let missing = Set(text.filter { !$0.isWhitespace && profile.glyphs[String($0)]?.isEmpty != false }).sorted { String($0) < String($1) }
        guard missing.isEmpty else { throw NotebookError.invalid("Diese Zeichen bitte zuerst trainieren: \(String(missing))") }
        guard profile.size > 0, profile.margin*2 < page.width, profile.margin*2 < page.height else { throw NotebookError.invalid("Schriftgröße oder Seitenrand passt nicht auf die Seite.") }
        var random = SeededRandom(seed:seed)
        var x = CGFloat(profile.margin), y = CGFloat(profile.margin)
        let right = page.width-CGFloat(profile.margin), bottom = page.height-CGFloat(profile.margin)
        var result: [PKStroke] = []
        let words = text.components(separatedBy:.whitespacesAndNewlines)
        var currentWord = 0
        let characters = Array(text)
        for (index,char) in characters.enumerated() {
            if char == "\n" { x = profile.margin; y += profile.size+profile.lineSpacing; currentWord += 1; continue }
            if char.isWhitespace { x += profile.wordSpacing; currentWord += 1; continue }
            if index == 0 || characters[index-1].isWhitespace {
                let word = currentWord < words.count ? words[currentWord] : ""
                var estimated:CGFloat = 0
                for c in word {
                    if let data = profile.glyphs[String(c)]?.first, let g = try? PKDrawing(data:data), g.bounds.height > 0 { estimated += g.bounds.width/g.bounds.height*profile.size+profile.size*0.12 }
                }
                if x > profile.margin && x+estimated > right { x = profile.margin; y += profile.size+profile.lineSpacing }
            }
            guard let variants = profile.glyphs[String(char)], !variants.isEmpty else { continue }
            let variant = Int(random.next() % UInt64(variants.count))
            let glyph = try PKDrawing(data:variants[variant]); let bounds = glyph.bounds
            guard bounds.height > 0 else { throw NotebookError.invalid("Leere Zeichenvariante.") }
            let variation = (random.unit()-0.5)*profile.irregularity
            let scale = CGFloat(profile.size*(1+variation))/bounds.height
            let width = bounds.width*scale
            if x+width > right { x = profile.margin; y += profile.size+profile.lineSpacing }
            guard x+width <= right, y+profile.size*(1+profile.irregularity) <= bottom else { throw NotebookError.invalid("Der Text passt nicht vollständig auf diese Seite. Verkleinere die Schrift oder füge eine Seite hinzu.") }
            let offset = CGFloat((random.unit()-0.5)*profile.irregularity*profile.size)
            let transform = CGAffineTransform(translationX:-bounds.minX,y:-bounds.minY).concatenating(CGAffineTransform(scaleX:scale,y:scale)).concatenating(CGAffineTransform(translationX:x,y:y+offset))
            let transformed = glyph.transformed(using:transform)
            for stroke in transformed.strokes { result.append(PKStroke(ink:PKInk(stroke.ink.inkType,color:UIColor(hex:profile.color)),path:stroke.path,transform:stroke.transform,mask:stroke.mask)) }
            x += width+profile.size*0.12
        }
        return result
    }
}
struct SeededRandom {
    var state:UInt64
    init(seed:UInt64) { state = seed }
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    mutating func unit() -> Double { Double(next() >> 11)/Double(UInt64(1)<<53) }
}

@MainActor final class TrainingPadController: ObservableObject {
    weak var coordinator: TrainingPad.Coordinator?
    func clear() { coordinator?.clear() }
    func drawing() -> PKDrawing { coordinator?.drawing ?? PKDrawing() }
}
@MainActor struct TrainingPad: UIViewRepresentable {
    let controller:TrainingPadController
    func makeCoordinator() -> Coordinator { Coordinator(controller:controller) }
    func makeUIView(context:Context) -> PKCanvasView {
        let canvas = PKCanvasView(); canvas.overrideUserInterfaceStyle = .light; canvas.backgroundColor = UIColor(hex:"#FAFBFD"); canvas.drawingPolicy = .anyInput; canvas.tool = PKInkingTool(.pen,color:.black,width:2); canvas.delegate = context.coordinator
        context.coordinator.canvas = canvas; return canvas
    }
    func updateUIView(_ canvas:PKCanvasView,context:Context) {}
    @MainActor final class Coordinator:NSObject,PKCanvasViewDelegate {
        var drawing = PKDrawing(); weak var canvas:PKCanvasView?
        init(controller:TrainingPadController) { super.init(); controller.coordinator = self }
        func canvasViewDrawingDidChange(_ canvasView:PKCanvasView) { drawing = canvasView.drawing }
        func clear() { drawing = PKDrawing(); canvas?.drawing = drawing }
    }
}

@MainActor struct HandwritingStudio: View {
    let commands:CanvasCommands
    let pageSize:CGSize
    @StateObject private var library:HandwritingLibrary
    @StateObject private var pad = TrainingPadController()
    @State private var selected:Character = "a"
    @State private var tab = 0
    @State private var text = ""
    @State private var busy = false
    init(commands:CanvasCommands,pageSize:CGSize,directory:URL) { self.commands = commands; self.pageSize = pageSize; _library = StateObject(wrappedValue:HandwritingLibrary(directory:directory)) }
    var body: some View {
        VStack(spacing:0) {
            Picker("Modus",selection:$tab) { Text("Zeichen trainieren").tag(0); Text("Text schreiben").tag(1) }.pickerStyle(.segmented).padding()
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    if tab == 0 {
                        Text("Deine Schrift. Deine Varianten.").font(.title2.bold())
                        Text("Schreibe jedes Zeichen mehrmals. Beim Einsetzen wechseln sich deine gespeicherten Formen ab.").font(.subheadline).foregroundStyle(.secondary)
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:37))],spacing:7) {
                            ForEach(HandwritingLibrary.alphabet,id:\.self) { char in
                                Button { selected = char; pad.clear() } label: { VStack(spacing:2) { Text(String(char)).font(.system(size:19)); Text("\(library.profile.glyphs[String(char)]?.count ?? 0)").font(.system(size:9)) }.frame(width:37,height:47).background(selected == char ? Theme.accent : Theme.sidebar,in:RoundedRectangle(cornerRadius:7)).foregroundStyle(.white) }
                            }
                        }
                        HStack { Text("Schreibe: \(String(selected))").font(.headline); Spacer(); Button("Leeren") { pad.clear() } }
                        TrainingPad(controller:pad).frame(height:180).clipShape(RoundedRectangle(cornerRadius:12)).overlay { RoundedRectangle(cornerRadius:12).stroke(Color.gray.opacity(0.2)) }
                        Button("Variante speichern") { do { try library.train(selected,drawing:pad.drawing()); pad.clear() } catch { library.message = error.localizedDescription } }.buttonStyle(.borderedProminent)
                    } else {
                        HStack { Text("Auf das aktuelle Blatt schreiben").font(.title2.bold()); Spacer(); Button("Blatt analysieren") { library.analyze(commands.snapshot(),original:commands.target?.viewport?.original.ink ?? OriginalInk()) } }
                        TextEditor(text:$text).scrollContentBackground(.hidden).frame(height:140).padding(8).background(Theme.sidebar,in:RoundedRectangle(cornerRadius:10)).overlay { RoundedRectangle(cornerRadius:10).stroke(Theme.border) }
                        HStack {
                            Button("Text schreiben") { do { let strokes = try library.synthesize(text,page:pageSize); try library.save(); commands.append(strokes); library.message = "\(strokes.count) Striche eingefügt." } catch { library.message = error.localizedDescription } }.buttonStyle(.borderedProminent).disabled(text.isEmpty)
                            Button(busy ? "Wird erstellt …" : "KI-Text erstellen") { aiText() }.buttonStyle(.bordered).disabled(busy || text.isEmpty)
                        }
                        slider("Buchstabengröße",value:$library.profile.size,range:8...80)
                        slider("Wortabstand",value:$library.profile.wordSpacing,range:2...50)
                        slider("Zeilenabstand",value:$library.profile.lineSpacing,range:0...60)
                        slider("Unregelmäßigkeit",value:$library.profile.irregularity,range:0...0.4)
                        slider("Seitenränder",value:$library.profile.margin,range:8...150)
                    }
                    if !library.message.isEmpty { Text(library.message).font(.callout).padding().frame(maxWidth:.infinity,alignment:.leading).background(Theme.sidebar,in:RoundedRectangle(cornerRadius:10)) }
                }.padding(24)
            }
        }.goodnotesSheet().navigationTitle("Handschrift-Studio").navigationBarTitleDisplayMode(.inline).tint(Theme.accent)
        .onDisappear { do { try library.save() } catch { commands.reportError(error.localizedDescription) } }
    }
    private func slider(_ label:String,value:Binding<Double>,range:ClosedRange<Double>) -> some View { VStack(alignment:.leading) { HStack { Text(label); Spacer(); Text(value.wrappedValue.formatted(.number.precision(.fractionLength(1)))).monospacedDigit().foregroundStyle(.secondary) }; Slider(value:value,in:range) } }
    private func aiText() {
        busy = true
        Task { do { text = try await ExtensionAPI.generate(prompt:text); library.message = "Text bereit. Prüfe ihn vor dem Einsetzen." } catch { library.message = error.localizedDescription }; busy = false }
    }
}
