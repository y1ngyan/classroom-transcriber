import SwiftUI
import WebKit

/// 轻量 Markdown → HTML。只覆盖模型实际会产的语法：
/// 标题、粗斜体、列表、表格、引用、分隔线、行内代码、链接、时间戳。
enum MarkdownRenderer {

    static func html(from markdown: String) -> String {
        var body = ""
        var listBuffer: [String] = []
        var tableBuffer: [[String]] = []
        var inCodeBlock = false
        var codeBuffer: [String] = []

        func flushList() {
            guard !listBuffer.isEmpty else { return }
            body += "<ul>" + listBuffer.joined() + "</ul>\n"
            listBuffer.removeAll()
        }

        func flushTable() {
            guard !tableBuffer.isEmpty else { return }
            var html = "<table>"
            for (index, cells) in tableBuffer.enumerated() {
                // 第二行是 |---|---| 的分隔行，跳过
                if index == 1, cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " } }) {
                    continue
                }
                let tag = index == 0 ? "th" : "td"
                html += "<tr>" + cells.map { "<\(tag)>\(inline($0))</\(tag)>" }.joined() + "</tr>"
            }
            html += "</table>\n"
            body += html
            tableBuffer.removeAll()
        }

        func flushAll() {
            flushList()
            flushTable()
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // 代码块
            if line.hasPrefix("```") {
                if inCodeBlock {
                    body += "<pre><code>" + escape(codeBuffer.joined(separator: "\n")) + "</code></pre>\n"
                    codeBuffer.removeAll()
                } else {
                    flushAll()
                }
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock {
                codeBuffer.append(rawLine)
                continue
            }

            // 表格
            if line.hasPrefix("|"), line.hasSuffix("|") {
                flushList()
                let cells = line
                    .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                tableBuffer.append(cells)
                continue
            } else {
                flushTable()
            }

            // 空行
            if line.isEmpty {
                flushList()
                continue
            }

            // 分隔线
            if line == "---" || line == "***" || line == "___" {
                flushList()
                body += "<hr>\n"
                continue
            }

            // 标题
            if let heading = headingLevel(line) {
                flushList()
                body += "<h\(heading.level)>\(inline(heading.text))</h\(heading.level)>\n"
                continue
            }

            // 引用
            if line.hasPrefix("> ") {
                flushList()
                body += "<blockquote>\(inline(String(line.dropFirst(2))))</blockquote>\n"
                continue
            }

            // 无序列表
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                listBuffer.append("<li>\(inline(String(line.dropFirst(2))))</li>")
                continue
            }

            // 有序列表
            if let dotIndex = line.firstIndex(of: "."),
               line[line.startIndex..<dotIndex].allSatisfy(\.isNumber),
               line.index(after: dotIndex) < line.endIndex,
               line[line.index(after: dotIndex)] == " " {
                let content = String(line[line.index(dotIndex, offsetBy: 2)...])
                listBuffer.append("<li class=\"ordered\">\(inline(content))</li>")
                continue
            }

            // 普通段落
            flushList()
            body += "<p>\(inline(line))</p>\n"
        }

        if inCodeBlock, !codeBuffer.isEmpty {
            body += "<pre><code>" + escape(codeBuffer.joined(separator: "\n")) + "</code></pre>\n"
        }
        flushAll()

        return wrap(body)
    }

    // MARK: - 行内语法

    private static func inline(_ text: String) -> String {
        var output = escape(text)

        // 时间戳 [MM:SS] 或 [H:MM:SS] —— 高亮，方便回看录像定位
        output = output.replacingOccurrences(
            of: #"\[(\d{1,2}:\d{2}(?::\d{2})?)\]"#,
            with: "<span class=\"ts\">[$1]</span>",
            options: .regularExpression
        )

        // 行内代码
        output = output.replacingOccurrences(
            of: #"`([^`]+)`"#,
            with: "<code>$1</code>",
            options: .regularExpression
        )

        // 链接
        output = output.replacingOccurrences(
            of: #"\[([^\]]+)\]\((https?://[^\)]+)\)"#,
            with: "<a href=\"$2\">$1</a>",
            options: .regularExpression
        )

        // 粗体
        output = output.replacingOccurrences(
            of: #"\*\*([^\*]+)\*\*"#,
            with: "<strong>$1</strong>",
            options: .regularExpression
        )

        // 斜体
        output = output.replacingOccurrences(
            of: #"(?<!\*)\*([^\*]+)\*(?!\*)"#,
            with: "<em>$1</em>",
            options: .regularExpression
        )

        return output
    }

    private static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        for level in stride(from: 6, through: 1, by: -1) {
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) {
                return (level, String(line.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - 外壳与样式

    private static func wrap(_ body: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
          :root { color-scheme: light dark; }
          body {
            font: -apple-system-body;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
            font-size: 15px;
            line-height: 1.75;
            color: var(--fg);
            margin: 0;
            padding: 4px 6px 40px;
            -webkit-font-smoothing: antialiased;
          }
          :root { --fg: #1d1d1f; --muted: #6e6e73; --accent: #0071E3; --rule: #d2d2d7; }
          @media (prefers-color-scheme: dark) {
            :root { --fg: #f5f5f7; --muted: #a1a1a6; --rule: #3a3a3c; }
          }
          /* P14-4：笔记块的小节标题 17/600、正文 15（body 已定在 15）。
             30/23/18 那套是「文档网页」的比例，放进 App 卡片里比页面标题
             还大；标题层级只用字重和留白表达 */
          h1 { font-size: 32px; font-weight: 700; letter-spacing: -0.4px; margin: 32px 0 12px; }
          h2 { font-size: 17px; font-weight: 600; letter-spacing: -0.2px; margin: 24px 0 8px; }
          h3 { font-size: 15px; font-weight: 600; margin: 20px 0 6px; }
          h1:first-child, h2:first-child { margin-top: 8px; }
          p { margin: 10px 0; }
          ul { margin: 10px 0; padding-left: 22px; }
          li { margin: 5px 0; }
          li.ordered { list-style: decimal; }
          hr { border: none; border-top: 1px solid var(--rule); margin: 30px 0; }
          blockquote {
            margin: 14px 0; padding: 2px 0 2px 16px;
            border-left: 3px solid var(--rule); color: var(--muted);
          }
          code {
            font-family: "SF Mono", ui-monospace, Menlo, monospace;
            font-size: 0.88em; background: rgba(127,127,127,0.14);
            padding: 2px 5px; border-radius: 4px;
          }
          pre {
            background: rgba(127,127,127,0.1); padding: 14px 16px;
            border-radius: 10px; overflow-x: auto;
          }
          pre code { background: none; padding: 0; }
          table {
            border-collapse: collapse; width: 100%; margin: 16px 0; font-size: 13px;
          }
          th, td {
            text-align: left; padding: 9px 12px;
            border-bottom: 1px solid var(--rule);
          }
          th { font-weight: 600; color: var(--muted); font-size: 11px;
               text-transform: uppercase; letter-spacing: 0.4px; }
          a { color: var(--accent); text-decoration: none; }
          a:hover { text-decoration: underline; }
          .ts {
            font-family: "SF Mono", ui-monospace, Menlo, monospace;
            font-size: 0.85em; color: var(--accent);
            background: rgba(0,113,227,0.09);
            padding: 1px 5px; border-radius: 4px; white-space: nowrap;
          }
        </style></head>
        <body>\(body)</body></html>
        """
    }
}

/// 渲染 Markdown 的 WebView。高度自适应由外部控制。
struct MarkdownWebView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let html = MarkdownRenderer.html(from: markdown)
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?
    }
}
