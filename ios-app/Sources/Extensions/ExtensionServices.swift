import Foundation
import SwiftUI
import Security
import PencilKit
import UIKit

enum SecureStore {
    static func set(_ value:String,key:String) throws {
        let query:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"studio.nullmini",kSecAttrAccount as String:key]
        let status = SecItemUpdate(query as CFDictionary,[kSecValueData as String:Data(value.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query; entry[kSecValueData as String] = Data(value.utf8); entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(entry as CFDictionary,nil) == errSecSuccess else { throw NotebookError.invalid("Zugangsdaten konnten nicht im Schlüsselbund gespeichert werden.") }
        } else if status != errSecSuccess { throw NotebookError.invalid("Schlüsselbund nicht verfügbar.") }
    }
    static func get(_ key:String) -> String {
        let query:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"studio.nullmini",kSecAttrAccount as String:key,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var item:CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&item) == errSecSuccess, let data = item as? Data else { return "" }; return String(data:data,encoding:.utf8) ?? ""
    }
}

enum ExtensionAPI {
    static func endpoint(_ key:String) throws -> URL {
        guard let text = UserDefaults.standard.string(forKey:key), let url = URL(string:text), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw NotebookError.invalid("Trage unter Verbindungen zuerst die HTTPS-Adresse deines Dienstes ein.") }; return url
    }
    static func send(_ request:URLRequest) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 90; config.httpShouldSetCookies = false
        let session = URLSession(configuration:config); defer { session.invalidateAndCancel() }
        let (data,response) = try await session.data(for:request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw NotebookError.invalid("Der Dienst hat die Anfrage nicht erfolgreich beantwortet.") }
        guard data.count <= 10*1024*1024 else { throw NotebookError.invalid("Die Antwort ist zu groß.") }; return data
    }
    static func generate(prompt:String,image:Data? = nil) async throws -> String {
        var request = URLRequest(url:try endpoint("aiEndpoint")); request.httpMethod = "POST"; request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        let token = SecureStore.get("aiToken"); if !token.isEmpty { request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization") }
        var body = ["prompt":prompt]; if let image { body["imageBase64"] = image.base64EncodedString() }
        request.httpBody = try JSONEncoder().encode(body)
        struct Response:Decodable { let text:String }
        let answer = try JSONDecoder().decode(Response.self,from:await send(request))
        guard !answer.text.isEmpty else { throw NotebookError.invalid("Der Dienst hat keinen Text zurückgegeben.") }; return answer.text
    }
}

@MainActor struct ConnectionsView:View {
    @State private var ai = UserDefaults.standard.string(forKey:"aiEndpoint") ?? ""
    @State private var server = UserDefaults.standard.string(forKey:"serverEndpoint") ?? ""
    @State private var token = SecureStore.get("aiToken")
    @State private var user = SecureStore.get("serverUser")
    @State private var password = SecureStore.get("serverPassword")
    @State private var message = ""
    var body:some View {
        Form {
            Section("KI-Dienst") { TextField("HTTPS-Adresse",text:$ai).textInputAutocapitalization(.never).autocorrectionDisabled(); SecureField("API-Token",text:$token); Text("Nur wenn du KI-Text oder Solve Here startest, wird deine Eingabe an diesen Dienst gesendet.").font(.footnote).foregroundStyle(.secondary) }
            Section("Dell iDRAC / Redfish") { TextField("https://mein-server",text:$server).textInputAutocapitalization(.never).autocorrectionDisabled(); TextField("Benutzername",text:$user).textInputAutocapitalization(.never); SecureField("Passwort",text:$password) }
            Button("Verbindungen speichern") {
                do {
                    for value in [ai,server] where !value.isEmpty { guard let url = URL(string:value),url.scheme == "https",url.host != nil,url.user == nil,url.password == nil else { throw NotebookError.invalid("Bitte eine gültige HTTPS-Adresse verwenden.") } }
                    try SecureStore.set(token,key:"aiToken"); try SecureStore.set(user,key:"serverUser"); try SecureStore.set(password,key:"serverPassword")
                    UserDefaults.standard.set(ai,forKey:"aiEndpoint"); UserDefaults.standard.set(server,forKey:"serverEndpoint"); message = "Gespeichert."
                } catch { message = error.localizedDescription }
            }
            if !message.isEmpty { Text(message) }
        }.goodnotesSheet()
    }
}

@MainActor struct SolveHereView:View {
    let commands:CanvasCommands
    let pageSize:CGSize
    let directory:URL
    @State private var prompt = "Löse die Aufgabe auf diesem Blatt und erkläre den Rechenweg."
    @State private var answer = ""
    @State private var busy = false
    @State private var message = ""
    var body:some View {
        Form {
            Section("Aufgabe") { TextEditor(text:$prompt).scrollContentBackground(.hidden).frame(height:90); Text("Beim Start wird ein Bild der aktuellen Seite an deinen konfigurierten KI-Dienst gesendet.").font(.footnote).foregroundStyle(.secondary); Button(busy ? "Wird gelöst …" : "Solve Here starten") { solve() }.disabled(busy) }
            if !answer.isEmpty { Section("Ergebnis prüfen") { TextEditor(text:$answer).scrollContentBackground(.hidden).frame(minHeight:200); Button("In meiner trainierten Handschrift einsetzen") { do { let library = HandwritingLibrary(directory:directory); commands.append(try library.synthesize(answer,page:pageSize)); message = "Eingesetzt." } catch { message = error.localizedDescription } } } }
            if !message.isEmpty { Text(message) }
        }.goodnotesSheet()
    }
    private func solve() {
        busy = true
        let factor = min(1,1600/max(pageSize.width,pageSize.height)); let size = CGSize(width:pageSize.width*factor,height:pageSize.height*factor)
        let renderer = UIGraphicsImageRenderer(size:size)
        let image = renderer.image { ctx in
            ctx.cgContext.scaleBy(x:factor,y:factor)
            if let viewport = commands.target?.viewport { viewport.content.layer.render(in:ctx.cgContext) }
            else { commands.snapshot().paperImage(from:CGRect(origin:.zero,size:pageSize),scale:1).draw(in:CGRect(origin:.zero,size:pageSize)) }
        }.jpegData(compressionQuality:0.8)
        Task { do { answer = try await ExtensionAPI.generate(prompt:prompt,image:image); message = "" } catch { message = error.localizedDescription }; busy = false }
    }
}

struct ServerStatus:Decodable {
    struct HealthStatus:Decodable { let Health:String?; let State:String? }
    let Name:String?
    let Model:String?
    let PowerState:String?
    let Status:HealthStatus?
}
@MainActor struct ServerControlView:View {
    @State private var status:ServerStatus?
    @State private var systemPath:String?
    @State private var message = ""
    @State private var busy = false
    @State private var confirm = false
    var body:some View {
        Form {
            Section("iDRAC") { if let status { LabeledContent("Name",value:status.Name ?? "–"); LabeledContent("Modell",value:status.Model ?? "–"); LabeledContent("Strom",value:status.PowerState ?? "–"); LabeledContent("Zustand",value:status.Status?.Health ?? "–") }; Button(busy ? "Verbinden …" : "Status abrufen") { refresh() }.disabled(busy) }
            Section { Button("Server geordnet neu starten",role:.destructive) { confirm = true }.disabled(systemPath == nil || busy) }
            if !message.isEmpty { Text(message) }
        }.goodnotesSheet().confirmationDialog("Diesen Server jetzt neu starten?",isPresented:$confirm,titleVisibility:.visible) { Button("Neu starten",role:.destructive) { restart() }; Button("Abbrechen",role:.cancel) {} }
    }
    private func request(path:String,method:String = "GET",body:Data? = nil) throws -> URLRequest {
        let base = try ExtensionAPI.endpoint("serverEndpoint")
        guard path.hasPrefix("/redfish/v1/"), let url = URL(string:path,relativeTo:base)?.absoluteURL, url.host == base.host, url.port == base.port else { throw NotebookError.invalid("Ungültiger Redfish-Pfad.") }
        var r = URLRequest(url:url); r.httpMethod = method; r.httpBody = body
        let credentials = SecureStore.get("serverUser")+":"+SecureStore.get("serverPassword")
        r.setValue("Basic "+Data(credentials.utf8).base64EncodedString(),forHTTPHeaderField:"Authorization"); r.setValue("application/json",forHTTPHeaderField:"Content-Type"); return r
    }
    private func refresh() {
        busy = true
        Task { do {
            struct Member:Decodable { let path:String; enum CodingKeys:String,CodingKey { case path = "@odata.id" } }
            struct Collection:Decodable { let Members:[Member] }
            let members = try JSONDecoder().decode(Collection.self,from:await ExtensionAPI.send(request(path:"/redfish/v1/Systems")))
            guard let first = members.Members.first else { throw NotebookError.invalid("Kein System gefunden.") }
            status = try JSONDecoder().decode(ServerStatus.self,from:await ExtensionAPI.send(request(path:first.path))); systemPath = first.path; message = ""
        } catch { message = error.localizedDescription }; busy = false }
    }
    private func restart() {
        guard let systemPath else { return }; busy = true
        Task { do { _ = try await ExtensionAPI.send(request(path:systemPath+"/Actions/ComputerSystem.Reset",method:"POST",body:Data("{\"ResetType\":\"GracefulRestart\"}".utf8))); message = "Neustart angefordert." } catch { message = error.localizedDescription }; busy = false }
    }
}
