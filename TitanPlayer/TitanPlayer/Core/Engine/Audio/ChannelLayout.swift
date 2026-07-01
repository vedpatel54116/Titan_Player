import AudioToolbox

struct ChannelLayout {
    let channelCount: Int
    let channelDescriptions: [AudioChannelDescription]
    
    static let stereo = ChannelLayout(
        channelCount: 2,
        channelDescriptions: [
            AudioChannelDescription(mChannelLabel: kAudioChannelLabel_Left, mChannelFlags: [], mCoordinates: (0, 0, 0)),
            AudioChannelDescription(mChannelLabel: kAudioChannelLabel_Right, mChannelFlags: [], mCoordinates: (0, 0, 0))
        ]
    )
    
    static let surround5_1 = ChannelLayout(
        channelCount: 6,
        channelDescriptions: [
            AudioChannelDescription(mChannelLabel: kAudioChannelLabel_Left, mChannelFlags: [], mCoordinates: (0, 0, 0)),
            AudioChannelDescription(mChannelLabel: kAudioChannelLabel_Right, mChannelFlags: [], mCoordinates: (0, 0, 0)),
            AudioChannelDescription(mChannelLabel: kAudioChannelLabel_Center, mChannelFlags: [], mCoordinates: (0, 0, 0)),
            AudioChannelDescription(mChannelLabel: kAudioChannelLabel_LFEScreen, mChannelFlags: [], mCoordinates: (0, 0, 0)),
            AudioChannelDescription(mChannelLabel: kAudioChannelLabel_LeftSurround, mChannelFlags: [], mCoordinates: (0, 0, 0)),
            AudioChannelDescription(mChannelLabel: kAudioChannelLabel_RightSurround, mChannelFlags: [], mCoordinates: (0, 0, 0))
        ]
    )
}