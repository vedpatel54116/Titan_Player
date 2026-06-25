import Foundation
import Combine

@MainActor
class SubtitleManager: ObservableObject {
    @Published var availableTracks: [SubtitleTrack] = []
    @Published var activeTrack: SubtitleTrack?
    @Published var currentEvents: [SubtitleEvent] = []
    
    private var parsers: [String: SubtitleParsing] = [
        "srt": SRTParser(),
        "ass": ASSParser(),
        "ssa": ASSParser(),
        "vtt": WebVTTParser()
    ]
    
    func loadSubtitle(url: URL) throws {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        
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
    
    func update(for time: Double) {
        guard let track = activeTrack else {
            currentEvents = []
            return
        }
        
        currentEvents = track.events.filter { event in
            time >= event.startTime && time <= event.endTime
        }
    }
    
    func clear() {
        availableTracks = []
        activeTrack = nil
        currentEvents = []
    }
}
