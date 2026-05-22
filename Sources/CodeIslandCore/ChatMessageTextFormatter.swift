import Foundation

private final class BoxedAttributedString {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

public enum ChatMessageTextFormatter {
    private static let markdownCache: NSCache<NSString, BoxedAttributedString> = {
        let c = NSCache<NSString, BoxedAttributedString>()
        c.countLimit = 128
        return c
    }()

    public static func displayText(for message: ChatMessage) -> AttributedString {
        message.isUser ? literalText(message.text) : inlineMarkdown(message.text)
    }

    public static func literalText(_ text: String) -> AttributedString {
        AttributedString(text)
    }

    public static func inlineMarkdown(_ text: String) -> AttributedString {
        let key = text as NSString
        if let cached = markdownCache.object(forKey: key) { return cached.value }

        let result: AttributedString = text.contains("```")
            ? renderWithFencedCodeBlocks(text)
            : renderInlineOnly(text)

        markdownCache.setObject(BoxedAttributedString(result), forKey: key)
        return result
    }

    /// Apple's inline-only markdown parser treats ``` as inline code delimiters, which collapses
    /// fenced code blocks and leaks the language identifier into the text (issue #101). Split the
    /// input around fence markers and render code bodies literally, preserving newlines.
    private static func renderWithFencedCodeBlocks(_ text: String) -> AttributedString {
        var result = AttributedString()
        var buffer = ""
        var inFence = false
        var hasOutput = false

        func flush() {
            guard !buffer.isEmpty else { return }
            let piece = inFence ? AttributedString(buffer) : renderInlineOnly(buffer)
            if hasOutput {
                result.append(AttributedString("\n"))
            }
            result.append(piece)
            hasOutput = true
            buffer = ""
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inFence.toggle()
                continue
            }
            if !buffer.isEmpty { buffer.append("\n") }
            buffer.append(line)
        }
        flush()
        return result
    }

    private static func renderInlineOnly(_ text: String) -> AttributedString {
        if let attr = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attr
        }
        return AttributedString(text)
    }
}
