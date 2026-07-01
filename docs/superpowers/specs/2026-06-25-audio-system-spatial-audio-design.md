# Audio System with Spatial Audio Support - Design Document

## Overview

This document outlines the design for a comprehensive audio system with spatial audio support for TitanPlayer. The system will support multi-channel audio (up to 7.1.4 Dolby Atmos), spatial audio rendering with head tracking, audio passthrough for premium formats, and low-latency audio processing.

## Architecture Overview

### Core Components

1. **AudioEngine** - Main orchestrator using AVAudioEngine for high-level management
2. **SpatialRenderer** - AVAudioEnvironmentNode for 3D audio positioning
3. **CoreAudioBridge** - Low-level Core Audio integration for critical path optimization
4. **HeadTrackingManager** - Unified interface for multiple tracking sources
5. **FormatDecoder** - Multi-format audio decoder (Dolby Atmos, DTS:X, etc.)

### Data Flow

```
Source → FormatDecoder → AudioBuffer → SpatialRenderer → CoreAudioBridge → Output
```

### Key Design Decisions

- Extend existing AudioRenderer protocol with spatial capabilities
- Use AVAudioEngine for device management and basic routing
- Drop to Core Audio for buffer processing and low-latency requirements
- Unified head tracking interface supporting AirPods, external devices, and software emulation
- Hybrid approach combining AVAudioEngine high-level management with Core Audio low-level optimization

## Component Details

### 1. AudioEngine (Main Orchestrator)

**Responsibility**: Manage audio lifecycle, device routing, format detection

**Key Features**:
- Auto-detect audio format and configure appropriate decoder
- Manage audio session and device changes
- Provide unified API for playback control
- Handle error recovery and fallbacks

### 2. SpatialRenderer (3D Audio)

**Responsibility**: Spatial audio positioning and environmental effects

**Key Features**:
- HRTF (Head-Related Transfer Function) processing
- Room simulation with reverb and reflections
- Dynamic object positioning for Atmos content
- Real-time head tracking integration

### 3. CoreAudioBridge (Low-Level)

**Responsibility**: Direct Core Audio integration for performance

**Key Features**:
- Audio Unit management using `kAudioUnitSubType_HALOutput` and `kAudioUnitSubType_VoiceProcessingIO`
- Buffer management with lock-free queues using `OSAtomicEnqueue`/`OSAtomicDequeue`
- Sample rate conversion using Core Audio's built-in resampler or `libresample`
- Latency optimization with buffer size tuning (64-256 samples)
- Use `AudioComponentInstance` for custom audio unit instantiation

### 4. HeadTrackingManager

**Responsibility**: Unified head tracking interface

**Key Features**:
- AirPods Pro/Max integration via Core Motion (`CMHeadphoneMotionManager`)
- External device support using `IOKit` for USB/HID devices
- Software emulation with mouse/keyboard control (optional `CGEvent` monitoring)
- Calibration and smoothing algorithms using `simd_quatf` for quaternion math
- Unified `HeadTrackingSource` protocol for all tracking sources
- Support for both rotational and translational tracking

### 5. FormatDecoder

**Responsibility**: Multi-format audio decoding

**Key Features**:
- Dolby Atmos decoding using FFmpeg's `ac3` and `eac3` decoders
- DTS:X and DTS-HD MA support using FFmpeg's `dca` decoder
- PCM and legacy format fallback using Core Audio's `AudioConverter`
- Metadata extraction using `AVAsset` and custom parsers
- Support for container formats: MKV, MP4, MKA
- Channel layout detection and mapping to standard layouts

## Performance and Optimization

### Latency Optimization

**Target**: <50ms end-to-end latency

**Strategy**:
- Use Core Audio's low-latency audio units
- Implement lock-free buffer queues for real-time processing
- Optimize memory allocation patterns to avoid GC pauses
- Use dedicated real-time audio thread with high priority

### CPU Usage Control

**Target**: <3% for 7.1.4 audio on M1

**Strategy**:
- Leverage Apple Silicon's Neural Engine for HRTF processing
- Use SIMD operations for audio DSP calculations
- Implement adaptive quality based on system load
- Cache frequently used lookup tables

### Memory Management

**Strategy**:
- Pre-allocate audio buffers to avoid runtime allocation
- Use buffer pooling for frequently allocated/deallocated buffers
- Implement circular buffers for streaming audio
- Monitor memory usage and trigger warnings at thresholds

### Multi-Channel Support

**Target**: Up to 7.1.4 Dolby Atmos

**Strategy**:
- Dynamic channel routing based on output device capabilities
- Automatic downmixing for stereo/headphone output
- Object-based audio positioning for Atmos content
- Bed channel management for traditional surround formats

## Integration and Testing

### Integration with Existing Code

**Approach**: Extend existing AudioRenderer protocol

**Strategy**:
- Add new methods for spatial audio capabilities
- Maintain backward compatibility with existing code
- Implement adapter pattern for gradual migration
- Provide fallback to basic audio when spatial features unavailable

### Protocol Extensions

```swift
// Extend existing protocol
protocol SpatialAudioRenderer: AudioRenderer {
    var spatialAudioEnabled: Bool { get set }
    var headTrackingEnabled: Bool { get set }
    var audioQuality: AudioQuality { get set }
    
    func setListenerPosition(_ position: SIMD3<Float>)
    func setListenerOrientation(_ orientation: simd_quatf)
    func addAudioObject(_ object: AudioObject)
    func removeAudioObject(_ object: AudioObject)
    func updateAudioObject(_ object: AudioObject, position: SIMD3<Float>)
}

// New types
struct AudioObject {
    let id: UUID
    var position: SIMD3<Float>
    var gain: Float
    var spread: Float
    var source: AudioObjectSource
}

enum AudioQuality {
    case low      // 44.1kHz, 16-bit
    case medium   // 48kHz, 24-bit
    case high     // 96kHz, 32-bit
    case ultra    // 192kHz, 32-bit
}

enum AudioObjectSource {
    case bed(Int)           // Channel bed (1-7.1.4)
    case object(Int)        // Dynamic object
    case ambient(Int)       // Ambient sound
}
```

### Testing Strategy

**Unit Tests**:
- Test each component in isolation with mock dependencies
- Test audio buffer processing with known inputs/outputs
- Test head tracking with simulated device data
- Test format decoding with sample files

**Integration Tests**:
- Test complete audio pipeline from source to output
- Test device switching and format adaptation
- Test error recovery and fallback mechanisms
- Test performance under various load conditions

**Performance Tests**:
- Measure latency from input to output
- Monitor CPU usage during playback
- Track memory allocation patterns
- Test with various audio formats and channel configurations

### Error Handling

**Strategy**:
- Graceful degradation when spatial features unavailable
- Automatic fallback to stereo for unsupported formats
- User notification for format compatibility issues
- Recovery from audio device disconnections

### Monitoring and Diagnostics

**Features**:
- Real-time audio metrics using `os_log` and `OSAllocatingUnfairLock`
- Format detection and decoder status reporting
- Head tracking connection status with `CMHeadphoneMotionManager` state
- Debug logging with configurable log levels
- Performance counters using `mach_absolute_time()` for precise timing
- Memory usage tracking using `task_info()` for process memory

## Implementation Plan

This project is decomposed into 5 sub-projects with clear dependencies and implementation order.

### Sub-Project 1: Core Audio Infrastructure (Week 1-2)
**Dependencies**: None
**Deliverables**:
- CoreAudioBridge with low-latency audio units
- AudioEngine orchestrator with AVAudioEngine integration
- Buffer management and memory pooling
- Basic format detection and routing

**Milestone**: Basic audio playback with Core Audio

### Sub-Project 2: Format Support (Week 3-4)
**Dependencies**: Sub-Project 1
**Deliverables**:
- FormatDecoder for Dolby Atmos and DTS:X
- Metadata extraction and parsing
- FFmpeg integration for format support
- Format compatibility testing

**Milestone**: Dolby Atmos and DTS:X decoding

### Sub-Project 3: Spatial Audio Rendering (Week 5-6)
**Dependencies**: Sub-Project 1
**Deliverables**:
- SpatialRenderer with AVAudioEnvironmentNode
- HRTF processing and room simulation
- Basic 3D positioning and object management
- AirPods head tracking integration

**Milestone**: Spatial audio with AirPods head tracking

### Sub-Project 4: Advanced Head Tracking (Week 7-8)
**Dependencies**: Sub-Project 3
**Deliverables**:
- External device support (TrackIR, etc.)
- Software emulation with mouse/keyboard control
- Calibration and smoothing algorithms
- Unified tracking interface

**Milestone**: Full head tracking support

### Sub-Project 5: Integration and Testing (Week 9-10)
**Dependencies**: All previous sub-projects
**Deliverables**:
- Integration with existing PlaybackEngine
- Comprehensive testing suite
- Performance optimization and tuning
- Documentation and user guides

**Milestone**: Production-ready with comprehensive testing

### Implementation Order

```
Sub-Project 1 (Core Audio) → Sub-Project 2 (Format Support)
                            → Sub-Project 3 (Spatial Audio) → Sub-Project 4 (Head Tracking)
                                                            → Sub-Project 5 (Integration)
```

Note: Sub-Projects 2 and 3 can be developed in parallel after Sub-Project 1 is complete.

## Validation Criteria

- Dolby Atmos passthrough works correctly
- Spatial audio positioning accurate with head tracking
- No audio dropouts during playback
- CPU usage <3% for 7.1.4 audio on M1
- Latency <50ms from input to output

## Success Metrics

1. **Audio Quality**: Support for all major formats with proper decoding
2. **Spatial Accuracy**: Precise 3D positioning with head tracking
3. **Performance**: Meet latency and CPU usage targets
4. **Reliability**: No audio dropouts during extended playback
5. **Compatibility**: Works with AirPods Pro/Max and external tracking devices

## Risks and Mitigations

### Risk 1: Core Audio Complexity
- **Mitigation**: Start with AVAudioEngine, gradually drop to Core Audio for critical paths

### Risk 2: Format Support Limitations
- **Mitigation**: Use FFmpeg as fallback, implement progressive enhancement

### Risk 3: Head Tracking Latency
- **Mitigation**: Implement prediction algorithms, use high-frequency polling

### Risk 4: Memory Usage
- **Mitigation**: Implement strict memory budgets, use buffer pooling

## Future Considerations

1. **iOS/tvOS Support**: Extend to mobile platforms with appropriate optimizations
2. **Custom HRTF**: Allow users to load custom HRTF profiles
3. **Room Correction**: Advanced room acoustic correction algorithms
4. **Object-Based Mixing**: Real-time object mixing for custom spatial layouts
5. **Cloud Processing**: Offload heavy processing to cloud for low-end devices