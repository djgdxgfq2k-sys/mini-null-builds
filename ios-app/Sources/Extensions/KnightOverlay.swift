import SwiftUI
import SceneKit
import WebKit

@MainActor struct KnightOverlay: UIViewControllerRepresentable {
    let commands:CanvasCommands
    let pageSize:CGSize
    let directory:URL
    func makeUIViewController(context:Context) -> KnightController { KnightController(commands:commands,pageSize:pageSize,directory:directory) }
    func updateUIViewController(_ controller:KnightController,context:Context) {
        // Extension state is entirely owned by this controller. No canvas synchronization.
    }
}
final class PassthroughView:UIView {
    override func hitTest(_ point:CGPoint,with event:UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01 else { return nil }
        for child in subviews.reversed() {
            if let found = child.hitTest(convert(point,to:child),with:event) { return found }
        }
        return nil
    }
}

@MainActor final class KnightController:UIViewController {
    let commands:CanvasCommands
    let pageSize:CGSize
    let directory:URL
    private let knight = UIView()
    private var browser:UIViewController?
    init(commands:CanvasCommands,pageSize:CGSize,directory:URL) { self.commands = commands; self.pageSize = pageSize; self.directory = directory; super.init(nibName:nil,bundle:nil) }
    required init?(coder:NSCoder) { nil }
    override func loadView() { view = PassthroughView(); view.backgroundColor = .clear }
    override func viewDidLoad() {
        super.viewDidLoad(); view.addSubview(knight); knight.translatesAutoresizingMaskIntoConstraints = false
        knight.isHidden = !(UserDefaults.standard.object(forKey: "nullmini.knightVisible") as? Bool ?? false)
        NSLayoutConstraint.activate([knight.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-16),knight.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-32),knight.widthAnchor.constraint(equalToConstant:76),knight.heightAnchor.constraint(equalToConstant:110)])
        let sceneView = SCNView(); sceneView.scene = makeKnight(); sceneView.backgroundColor = .clear; sceneView.autoenablesDefaultLighting = true; sceneView.isUserInteractionEnabled = false; sceneView.preferredFramesPerSecond = 15; sceneView.antialiasingMode = .multisampling2X; sceneView.frame = CGRect(x:0,y:0,width:76,height:110); knight.addSubview(sceneView)
        let button = UIButton(type:.custom); button.frame = sceneView.frame; button.accessibilityLabel = "Ritter-Menü"; button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(title:"NullMini",children:[
            UIAction(title:"Solve Here",image:UIImage(systemName:"sparkles")) { [weak self] _ in self?.showSolver() },
            UIAction(title:"Unsichtbarkeitstrank",image:UIImage(systemName:"drop")) { [weak self] _ in self?.toggleStealth() },
            UIAction(title:"Silent Classroom Listener",image:UIImage(systemName:"waveform")) { [weak self] _ in self?.presentModule(title:"Classroom Listener",content:ListenerView()) },
            UIAction(title:"Split-Screen-Physik-Browser",image:UIImage(systemName:"rectangle.split.2x1")) { [weak self] _ in self?.toggleBrowser() },
            UIAction(title:"Dell-Server-Control",image:UIImage(systemName:"server.rack")) { [weak self] _ in self?.presentModule(title:"Server-Control",content:ServerControlView()) },
            UIMenu(options:.displayInline,children:[
                UIAction(title:"Handschrift-Studio",image:UIImage(systemName:"pencil.and.scribble")) { [weak self] _ in guard let self else { return }; self.presentModule(title:"Handschrift-Studio",content:HandwritingStudio(commands:self.commands,pageSize:self.pageSize,directory:self.directory)) },
                UIAction(title:"Verbindungen",image:UIImage(systemName:"network")) { [weak self] _ in self?.presentModule(title:"Verbindungen",content:ConnectionsView()) }
            ])
        ])
        knight.addSubview(button)
        commands.toggleKnight = { [weak self] in self?.toggleStealth() }
    }
    func toggleStealth() {
        knight.isHidden.toggle()
        UserDefaults.standard.set(!knight.isHidden, forKey: "nullmini.knightVisible")
        if knight.isHidden, let browser { remove(browser); self.browser = nil }
    }
    private func makeKnight() -> SCNScene {
        let scene = SCNScene(); let root = SCNNode(); scene.rootNode.addChildNode(root)
        func cube(_ w:CGFloat,_ h:CGFloat,_ d:CGFloat,_ x:Float,_ y:Float,_ z:Float,_ color:String) {
            let g = SCNBox(width:w,height:h,length:d,chamferRadius:0); g.firstMaterial?.diffuse.contents = UIColor(hex:color); g.firstMaterial?.roughness.contents = 0.88
            let n = SCNNode(geometry:g); n.position = SCNVector3(x,y,z); root.addChildNode(n)
        }
        cube(0.46,0.46,0.42,0,0.66,0,"#B8C9D4")
        cube(0.35,0.10,0.03,0,0.68,0.22,"#293C52")
        cube(0.06,0.07,0.04,-0.1,0.68,0.24,"#72D6DA"); cube(0.06,0.07,0.04,0.1,0.68,0.24,"#72D6DA")
        cube(0.41,0.48,0.28,0,0.18,0,"#6B879C")
        cube(0.12,0.16,0.04,0,0.24,0.16,"#E4B85F")
        cube(0.16,0.41,0.19,-0.3,0.18,0,"#A2B8C7"); cube(0.16,0.41,0.19,0.3,0.18,0,"#A2B8C7")
        cube(0.17,0.35,0.22,-0.12,-0.24,0,"#3D536A"); cube(0.17,0.35,0.22,0.12,-0.24,0,"#3D536A")
        cube(0.20,0.10,0.32,-0.12,-0.45,0.05,"#24364D"); cube(0.20,0.10,0.32,0.12,-0.45,0.05,"#24364D")
        root.eulerAngles = SCNVector3(-0.04,-0.3,0)
        let breathe = SCNAction.sequence([.moveBy(x:0,y:0.015,z:0,duration:2.5),.moveBy(x:0,y:-0.015,z:0,duration:2.5)]); root.runAction(.repeatForever(breathe))
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.usesOrthographicProjection = true; camera.camera?.orthographicScale = 1.75; camera.position = SCNVector3(0,0.2,3); scene.rootNode.addChildNode(camera)
        return scene
    }
    func presentModule<V:View>(title:String,content:V) {
        guard presentedViewController == nil else { return }
        let host = UIHostingController(rootView:ModuleShell(title:title,content:content)); host.modalPresentationStyle = .pageSheet; host.overrideUserInterfaceStyle = .dark
        host.sheetPresentationController?.detents = [.large()]; present(host,animated:true)
    }
    private func showSolver() { presentModule(title:"Solve Here",content:SolveHereView(commands:commands,pageSize:pageSize,directory:directory)) }
    private func toggleBrowser() {
        if let browser { remove(browser); self.browser = nil; return }
        let host = UIHostingController(rootView:PhysicsBrowserView(close:{ [weak self] in self?.toggleBrowser() }).preferredColorScheme(.dark))
        addChild(host); view.addSubview(host.view); host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([host.view.trailingAnchor.constraint(equalTo:view.trailingAnchor),host.view.topAnchor.constraint(equalTo:view.topAnchor,constant:66),host.view.bottomAnchor.constraint(equalTo:view.bottomAnchor),host.view.widthAnchor.constraint(equalTo:view.widthAnchor,multiplier:0.48)])
        host.didMove(toParent:self); browser = host; view.bringSubviewToFront(knight)
    }
    private func remove(_ child:UIViewController) { child.willMove(toParent:nil); child.view.removeFromSuperview(); child.removeFromParent() }
}
@MainActor struct ModuleShell<Content:View>:View {
    @Environment(\.dismiss) private var dismiss
    let title:String
    let content:Content
    var body:some View { NavigationStack { content.goodnotesSheet().navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement:.confirmationAction) { Button("Fertig") { dismiss() } } } }.tint(Theme.accent).preferredColorScheme(.dark) }
}
@MainActor struct PhysicsBrowserView:View {
    let close:()->Void
    @State private var address = "https://phet.colorado.edu/de/"
    @State private var current = URL(string:"https://phet.colorado.edu/de/")!
    var body:some View {
        VStack(spacing:0) {
            HStack { Image(systemName:"globe"); TextField("Webadresse",text:$address).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { navigate() }; Button(action:navigate) { Image(systemName:"arrow.right.circle") }; Button(action:close) { Image(systemName:"xmark") } }.font(.system(size:14)).padding(12).background(Theme.sidebar).foregroundStyle(.white)
            PhysicsWebView(url:current)
        }.background(Theme.library).overlay(alignment:.leading) { Rectangle().fill(Theme.border).frame(width:1) }.tint(Theme.accent).shadow(color:.black.opacity(0.3),radius:14,x:-5)
    }
    private func navigate() { if let url = URL(string:address), url.scheme == "https", url.host != nil { current = url } }
}
@MainActor struct PhysicsWebView:UIViewRepresentable {
    let url:URL
    final class Coordinator { var requested:URL? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context:Context) -> WKWebView { let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); let view = WKWebView(frame:.zero,configuration:config); context.coordinator.requested = url; view.load(URLRequest(url:url)); return view }
    func updateUIView(_ view:WKWebView,context:Context) { if context.coordinator.requested != url { context.coordinator.requested = url; view.load(URLRequest(url:url)) } }
}
