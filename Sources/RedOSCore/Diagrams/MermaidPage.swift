import Foundation

/// A Mermaid diagram as an HTML page on RedOS's black: Mermaid comes from `scriptURL`, or is injected by the app.
public enum MermaidPage {
    /// The page posts its height to `window.webkit.messageHandlers.size` once drawn.
    public static func html(
        _ source: String, title: String, scriptURL: String? = nil, maxHeight: Int? = nil
    ) -> String {
        let script = scriptURL.map { #"<script src="\#(escaped($0))"></script>"# } ?? ""
        let limit = maxHeight.map { "max-height: \($0)px;" } ?? ""
        let padding = maxHeight == nil ? 24 : 0
        return """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"><title>\(escaped(title))</title>
            <style>
            :root { color-scheme: dark; --bg: #000; --text: #f2f2f7; --muted: #8e8e93; }
            html, body { margin: 0; background: var(--bg); color: var(--text); font: 13px -apple-system, sans-serif; }
            .mermaid { margin: 0; padding: \(padding)px; display: flex; justify-content: center; }
            .mermaid:not([data-processed]) { visibility: hidden; }
            .mermaid svg { max-width: 100%; height: auto; \(limit) }
            .source { margin: 0; padding: \(padding)px; white-space: pre-wrap; color: var(--muted); }
            </style>
            \(script)
            </head><body><pre class="mermaid">\(escaped(source))</pre>
            <script>
            const source = \(javaScriptString(source));
            const sendHeight = () =>
              window.webkit?.messageHandlers?.size?.postMessage(document.documentElement.scrollHeight);
            mermaid.initialize({
              startOnLoad: false, securityLevel: "strict", theme: "base",
              themeVariables: {
                darkMode: true, background: "#000000", fontFamily: "-apple-system, sans-serif", fontSize: "14px",
                primaryColor: "#1c1c1e", primaryTextColor: "#f2f2f7", primaryBorderColor: "#ff453a",
                secondaryColor: "#2c2c2e", tertiaryColor: "#2c2c2e", lineColor: "#8e8e93", textColor: "#f2f2f7"
              }
            });
            mermaid.run({ querySelector: ".mermaid" }).catch(() => {
              const pre = document.querySelector(".mermaid");
              pre.className = "source";
              pre.textContent = source;
            }).finally(sendHeight);
            </script>
            </body></html>
            """
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A JavaScript string literal that cannot close the script element.
    static func javaScriptString(_ text: String) -> String {
        let json = (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return json.replacingOccurrences(of: "</", with: "<\\/")
    }
}
