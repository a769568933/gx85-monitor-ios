import Foundation

public enum CameraShootingMode: Equatable, Sendable { case photo, video, unknown }
public enum CameraRecordingState: Equatable, Sendable { case stopped, recording, unknown }

public struct CameraControlState: Equatable, Sendable {
    public let shootingMode: CameraShootingMode
    public let recordingState: CameraRecordingState
    public let isBusy: Bool?
    public let cardStatus: String?
    public let remainingPhotos: Int?
    public let rawFields: [String: String]

    /// GX80/GX85 report rec/play; some Lumix bodies report recmode/playmode.
    /// Neither spelling identifies the physical photo/video dial.
    public var isPlayback: Bool? {
        switch rawFields["cammode"]?.lowercased() {
        case "play", "playmode": return true
        case "rec", "recmode": return false
        default: return nil
        }
    }

    public init(response: LumixResponse) {
        rawFields = response.fields
        guard response.status == .success else {
            shootingMode = .unknown; recordingState = .unknown; isBusy = nil
            cardStatus = nil; remainingPhotos = nil
            return
        }
        let fields = response.fields
        switch fields["rec"]?.lowercased() {
        case "on": recordingState = .recording
        case "off": recordingState = .stopped
        default: recordingState = .unknown
        }
        // cammode=recmode describes record/playback, not the physical photo/video dial.
        // Only active recording establishes a video operation from the state reply.
        shootingMode = recordingState == .recording ? .video : .unknown
        switch fields["busy"]?.lowercased() {
        case "on", "yes", "1": isBusy = true
        case "off", "no", "0": isBusy = false
        default: isBusy = fields["sd_access"]?.lowercased() == "on" ? true : nil
        }
        cardStatus = fields["sdcardstatus"]
        remainingPhotos = (fields["remaincapacity"] ?? fields["recremaincapacity"]).flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
    }
}
