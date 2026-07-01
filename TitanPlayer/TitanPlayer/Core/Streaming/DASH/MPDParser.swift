import Foundation

enum MPDParserError: Error, LocalizedError {
    case fetchFailed(String)
    case invalidXML(String)
    case missingRequiredElement(String)

    var errorDescription: String? {
        switch self {
        case .fetchFailed(let msg): return "Failed to fetch MPD: \(msg)"
        case .invalidXML(let msg): return "Invalid MPD XML: \(msg)"
        case .missingRequiredElement(let el): return "Missing required element: \(el)"
        }
    }
}

actor MPDParser {
    static func parse(url: URL) async throws -> MPDManifest {
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw MPDParserError.fetchFailed("HTTP \(response)")
        }

        return try parse(data: data, baseURL: url)
    }

    static func parse(data: Data, baseURL: URL) throws -> MPDManifest {
        let parser = _MPDParserDelegate(baseURL: baseURL)
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()

        guard let manifest = parser.result else {
            throw MPDParserError.invalidXML(parser.parseError ?? "Unknown error")
        }
        return manifest
    }
}

private class _MPDParserDelegate: NSObject, XMLParserDelegate {
    let baseURL: URL
    var result: MPDManifest?
    var parseError: String?

    private var currentElement = ""
    private var currentAttributes: [String: String] = [:]
    private var textContent = ""

    private var mpdType: MPDManifest.MPDType = .static
    private var mpdDuration: Double?
    private var mpdMinBuffer: Double?

    private var adaptationSets: [[String: Any]] = []
    private var currentAdaptationSet: [String: Any]?
    private var representations: [DASHQuality] = []
    private var currentRepresentation: DASHQuality?
    private var currentBaseUrl: String?

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = elementName
        currentAttributes = attributes
        textContent = ""

        switch elementName {
        case "MPD":
            if let type = attributes["type"], type == "dynamic" {
                mpdType = .dynamic
            }
            mpdDuration = attributes["mediaPresentationDuration"].flatMap { parseDuration($0) }
            mpdMinBuffer = attributes["minBufferTime"].flatMap { parseDuration($0) }

        case "AdaptationSet":
            currentAdaptationSet = [
                "id": attributes["id"] as Any,
                "mimeType": attributes["mimeType"] as Any,
                "lang": attributes["lang"] as Any
            ]
            representations = []

        case "Representation":
            let repId = attributes["id"] ?? UUID().uuidString
            let bandwidth = Int(attributes["bandwidth"] ?? "0") ?? 0
            let width = attributes["width"].flatMap { Int($0) }
            let height = attributes["height"].flatMap { Int($0) }
            let codec = attributes["codecs"]
            let mimeType = attributes["mimeType"]

            currentRepresentation = DASHQuality(
                id: repId,
                bandwidth: bandwidth,
                width: width,
                height: height,
                codec: codec,
                mimeType: mimeType,
                baseUrl: nil
            )

        case "BaseURL":
            textContent = ""

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textContent += string
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError.localizedDescription
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "BaseURL":
            currentBaseUrl = textContent.trimmingCharacters(in: .whitespacesAndNewlines)

        case "Representation":
            if var rep = currentRepresentation {
                if let base = currentBaseUrl {
                    rep = DASHQuality(
                        id: rep.id, bandwidth: rep.bandwidth,
                        width: rep.width, height: rep.height,
                        codec: rep.codec, mimeType: rep.mimeType,
                        baseUrl: base
                    )
                }
                representations.append(rep)
            }
            currentRepresentation = nil

        case "AdaptationSet":
            if let mimeType = currentAdaptationSet?["mimeType"] as? String {
                let adaptSet = MPDManifest.AdaptationSet(
                    id: currentAdaptationSet?["id"] as? String,
                    mimeType: mimeType,
                    lang: currentAdaptationSet?["lang"] as? String,
                    representations: representations
                )
                adaptationSets.append(["set": adaptSet, "mimeType": mimeType])
            }
            currentAdaptationSet = nil
            representations = []

        case "MPD":
            let videoAdaptations = adaptationSets
                .filter { ($0["mimeType"] as? String)?.hasPrefix("video") == true }
                .compactMap { $0["set"] as? MPDManifest.AdaptationSet }
            let audioAdaptations = adaptationSets
                .filter { ($0["mimeType"] as? String)?.hasPrefix("audio") == true }
                .compactMap { $0["set"] as? MPDManifest.AdaptationSet }

            result = MPDManifest(
                type: mpdType,
                mediaPresentationDuration: mpdDuration,
                minBufferTime: mpdMinBuffer,
                videoAdaptations: videoAdaptations,
                audioAdaptations: audioAdaptations
            )

        default:
            break
        }
    }

    private func parseDuration(_ s: String) -> Double? {
        let regex = try? NSRegularExpression(pattern: "PT(?:(\\d+)H)?(?:(\\d+)M)?(?:([\\d.]+)S)?")
        guard let regex = regex else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let match = regex.firstMatch(in: s, range: range) else { return nil }

        let hours = match.range(at: 1).location != NSNotFound
            ? Double(s[Range(match.range(at: 1), in: s)!])! : 0
        let minutes = match.range(at: 2).location != NSNotFound
            ? Double(s[Range(match.range(at: 2), in: s)!])! : 0
        let seconds = match.range(at: 3).location != NSNotFound
            ? Double(s[Range(match.range(at: 3), in: s)!])! : 0

        return hours * 3600 + minutes * 60 + seconds
    }
}
