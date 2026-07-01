import Foundation
import Combine

@MainActor
class SubtitleManager: ObservableObject {
    @Published var availableTracks: [SubtitleTrack] = []
    @Published var activeTrack: SubtitleTrack?
    @Published var currentEvents: [SubtitleEvent] = []
    @Published var currentBitmap: SubtitleBitmap?
    
    private var parsers: [String: SubtitleParsing] = [
        "srt": SRTParser(),
        "ass": ASSParser(),
        "ssa": ASSParser(),
        "vtt": WebVTTParser()
    ]
    
    private var subtitleRenderer: SubtitleRenderer?
    
    init() {
        subtitleRenderer = LibAssRenderer()
    }
    
    func loadSubtitle(url: URL) throws {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        
        let isASS = ext == "ass" || ext == "ssa"
        
        if isASS {
            guard let renderer = subtitleRenderer else {
                throw MediaError(
                    code: .unsupportedFormat,
                    message: "Install libass for ASS subtitle support: brew install libass"
                )
            }
            try renderer.load(data: data, encoding: .utf8)
            let track = SubtitleTrack(
                name: url.lastPathComponent,
                language: nil,
                isDefault: availableTracks.isEmpty,
                events: []
            )
            availableTracks.append(track)
            if activeTrack == nil { activeTrack = track }
            return
        }
        
        guard let parser = parsers[ext] else {
            throw MediaError(code: .unsupportedFormat, message: "Unsupported subtitle format: \(ext)")
        }
        
        let events = try parser.parse(data: data)
        let track = SubtitleTrack(
            name: url.lastPathComponent,
            language: nil,
            isDefault: availableTracks.isEmpty,
            events: events
        )
        
        availableTracks.append(track)
        
        if activeTrack == nil {
            activeTrack = track
        }
    }
    
    func setActiveTrack(_ track: SubtitleTrack?) {
        activeTrack = track
    }
    
    func update(for time: Double, renderSize: CGSize = CGSize(width: 1920, height: 1080)) {
        guard let track = activeTrack else {
            currentEvents = []
            currentBitmap = nil
            return
        }
        
        let ext = (track.name as NSString).pathExtension.lowercased()
        let isASS = ext == "ass" || ext == "ssa"
        
        if isASS {
            currentEvents = []
            if let renderer = subtitleRenderer {
                currentBitmap = renderer.renderImage(forTime: time, size: renderSize)
            }
        } else {
            currentBitmap = nil
            currentEvents = track.events.filter { event in
                time >= event.startTime && time <= event.endTime
            }
        }
    }
    
    func clear() {
        subtitleRenderer?.flush()
        availableTracks = []
        activeTrack = nil
        currentEvents = []
        currentBitmap = nil
    }
}
