/// Arnav Island's sharing protocol, as Windows speaks it (ShareService.cpp) and the Android app's Wire.kt has it.
public enum Proto {
    public static let version = 2
    /// Revision 8 (island 0.25): offers with a picture, photos just taken, pages handed over where they were scrolled to.
    public static let revision = 8
    public static let magic: [UInt8] = [0x41, 0x52, 0x4E, 0x56]
    public static let chunk = 256 * 1024
    public static let maxFrame = chunk + 64

    public static let modePair = 0x50, modeSend = 0x53, modeMusic = 0x48, modeList = 0x4C, modeTake = 0x54
    public static let modeRemote = 0x52, modeNotice = 0x4E, modeFind = 0x46, modeQuery = 0x51, modeMirror = 0x56
    public static let modeInput = 0x49, modeAction = 0x41, modeClip = 0x43, modeCamera = 0x4B

    public static let frameOffer = 1, frameData = 1, frameEnd = 2, frameHeader = 3, frameBatchEnd = 4
    public static let frameMusic = 5, frameShelf = 6, frameTake = 7
    public static let frameRequest = 0x20, frameReply = 0x21
    public static let frameNotice = 0x30, frameNoticeAck = 0x31
    public static let frameRing = 0x40, frameRingAck = 0x41
    public static let frameQuery = 0x80, frameQueryReply = 0x81
    public static let frameAction = 0x70, frameActionAck = 0x71, frameClip = 0x50, frameClipAck = 0x51, frameCamera = 0x42, frameCameraAck = 0x43

    public static let cmdStatus = 1, cmdMedia = 2, cmdVolume = 3, cmdMute = 4, cmdLock = 5, cmdClipGet = 6, cmdClipSet = 7, cmdSeek = 8, cmdOpen = 9
    public static let cmdRingPc = 10, cmdLyrics = 11, cmdStats = 12, cmdSettings = 13, cmdControls = 14, cmdCommand = 15, cmdAudio = 16, cmdIsland = 17
    public static let cmdBattery = 18, cmdPage = 19

    public static let queryReadings = 1, queryFocus = 2, queryPhoto = 3, queryPage = 4

    public static let screenRequest = 0xA0, screenReply = 0xA1, screenVideo = 0xA2, screenFeedback = 0xA3, screenKeyframe = 0xA4
    public static let screenLimits = 0xA5, screenTouch = 0xA6, screenButton = 0xA7, screenText = 0xA8, screenInput = 0xA9, screenStop = 0xAF

    public static let inputMove = 0x60, inputButton = 0x61, inputScroll = 0x62, inputText = 0x63, inputKey = 0x64, inputPoint = 0x65

    public static let noticeStatus = 1, noticeNotification = 2, noticeDetails = 3, noticeGone = 4, noticeHotspot = 5, noticePhoto = 6

    public static let offerFolder = 1, offerShelf = 2, offerPicture = 4, offerAsked = 8

    public static let ok = 0, notAllowed = 1, unsupported = 2, failed = 3

    public static let shelfMax = 32
    public static let previewLimit = 6 * 1024
    public static let coverLimit = 96 * 1024
    public static let maxFile: Int64 = 16 << 30
    public static let maxTotal: Int64 = 1 << 40
    public static let maxFiles = 20000
}
