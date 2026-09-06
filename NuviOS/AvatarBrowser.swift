#if os(iOS) || os(macOS)
import SwiftUI
import Combine
import WebKit

/// An in-app browser for choosing a profile picture by its image URL.
///
/// The avatar gallery hands out direct image links, and typing one of those on
/// a TV or pasting it between apps on a phone is the worst part of setting a
/// custom avatar. So the browser opens on the gallery, and **tapping any image
/// on any page** applies that image's URL and closes — the page doesn't have to
/// cooperate, because the pick is read from the `<img>` itself.
///
/// tvOS has no `WKWebView`, so this whole file is off there; that platform
/// keeps the plain URL field.
struct AvatarBrowser: View {
    /// Called with the chosen image URL. The editor writes it into its field.
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = AvatarBrowserModel()

    var body: some View {
        NavigationStack {
            AvatarWebView(model: model)
                .ignoresSafeArea(edges: .bottom)
            .navigationTitle(model.title.isEmpty ? "Choose an avatar" : model.title)
            .platformInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Paste link", systemImage: "doc.on.clipboard") {
                        if let text = Self.clipboardText, isImageURL(text) {
                            finish(with: text)
                        } else {
                            model.pasteFailed = true
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { navigationBar }
            .alert("That isn't an image link", isPresented: $model.pasteFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("The clipboard needs to hold a link starting with http:// or https://.")
            }
        }
        .onAppear { model.start() }
        // Tapping a picture in the browser is the choice — there is nothing to
        // confirm afterwards, so it applies and closes straight away.
        .onChange(of: model.picked) { _, picked in
            guard let picked else { return }
            finish(with: picked)
        }
    }

    // MARK: Pieces

    private var navigationBar: some View {
        HStack(spacing: 14) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .buttonStyle(.plain)

            Text(model.displayHost)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Actions

    private func finish(with url: String) {
        onPick(url)
        dismiss()
    }

    private func isImageURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return false }
        return URL(string: trimmed) != nil
    }

    private static var clipboardText: String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }
}

// MARK: - Model

/// Owns the web view so the SwiftUI chrome can drive it, and receives the
/// picked image URL from the injected script.
@MainActor
final class AvatarBrowserModel: NSObject, ObservableObject {
    /// Where the browser opens: the avatar gallery.
    static let home = URL(string: "https://nuvioapple.github.io/Avatars/")!

    @Published var title = ""
    @Published var displayHost = ""
    @Published var canGoBack = false
    @Published var isLoading = false
    @Published var pasteFailed = false
    /// The image the viewer tapped. Set once, then the sheet closes.
    @Published var picked: String?

    let webView: WKWebView
    private var hasStarted = false

    override init() {
        let controller = WKUserContentController()
        controller.addUserScript(
            WKUserScript(source: Self.pickerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        )
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        controller.add(self, name: "pick")
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        webView.load(URLRequest(url: Self.home))
    }

    func goBack() { webView.goBack() }
    func reload() { webView.reload() }

    private func sync() {
        title = webView.title ?? ""
        canGoBack = webView.canGoBack
        isLoading = webView.isLoading
        displayHost = webView.url?.host ?? Self.home.host ?? ""
    }

    /// Tapping any `<img>` reports its resolved source. Reading `currentSrc`
    /// first matters for responsive images, where `src` may be a placeholder.
    private static let pickerScript = """
    (function(){
      if (window.__nuvioPicker) { return; }
      window.__nuvioPicker = true;
      document.addEventListener('click', function(event){
        var node = event.target;
        var img = node && node.closest ? node.closest('img') : null;
        if (!img) { return; }
        var src = img.currentSrc || img.src;
        if (!src || src.indexOf('data:') === 0) { return; }
        event.preventDefault();
        event.stopPropagation();
        window.webkit.messageHandlers.pick.postMessage(src);
      }, true);
    })();
    """
}

extension AvatarBrowserModel: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let src = message.body as? String else { return }
        Task { @MainActor in
            guard self.picked == nil else { return }   // first tap wins
            self.picked = src
        }
    }
}

extension AvatarBrowserModel: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.sync() }
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in self.sync() }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in self.sync() }
    }
}

// MARK: - Web view

#if os(iOS)
struct AvatarWebView: UIViewRepresentable {
    @ObservedObject var model: AvatarBrowserModel

    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ webView: WKWebView, context: Context) { }
}
#else
struct AvatarWebView: NSViewRepresentable {
    @ObservedObject var model: AvatarBrowserModel

    func makeNSView(context: Context) -> WKWebView { model.webView }
    func updateNSView(_ webView: WKWebView, context: Context) { }
}
#endif
#endif
