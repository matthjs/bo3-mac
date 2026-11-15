import Foundation

extension String {
    /// Decodes the HTML entities a scraped `<title>` can contain. The Workshop
    /// page escapes titles, so a map named "Zombies & Co." listed as
    /// "Zombies &amp; Co." when the Web API was unavailable.
    ///
    /// Handles numeric references and the named entities Steam emits.
    /// NSAttributedString's HTML importer would cover more, but it's
    /// main-thread only and far heavier for a title.
    var decodingHTMLEntities: String {
        guard contains("&") else { return self }

        let named: [Substring: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        ]

        var result = ""
        var rest = self[...]
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let afterAmp = rest.index(after: amp)
            // Entities are short; a far-off ';' means this '&' is literal text.
            guard let semi = rest[afterAmp...].prefix(10).firstIndex(of: ";") else {
                result += "&"
                rest = rest[afterAmp...]
                continue
            }

            let body = rest[afterAmp..<semi]
            var decoded: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                decoded = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
            } else if body.hasPrefix("#") {
                decoded = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
            } else {
                decoded = named[body]
            }

            if let decoded {
                result += decoded
                rest = rest[rest.index(after: semi)...]
            } else {
                result += "&"
                rest = rest[afterAmp...]
            }
        }
        result += rest
        return result
    }
}
