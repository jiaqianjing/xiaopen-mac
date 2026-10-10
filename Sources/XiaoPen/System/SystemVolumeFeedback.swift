import Foundation

/// Confirmation text is derived only from the device state read back by CoreAudio.
enum SystemVolumeFeedback {
    static func message(for result: SystemVolumeResult, command: SystemVolumeCommand) -> String {
        let state = result.after
        let volume = state.volumePercent.map { "\($0)%" }
        var message: String
        switch command {
        case .query:
            message = volume.map { "当前系统音量为\($0)。" }
                ?? "当前输出设备不提供系统音量读数。"
        case .setPercent, .adjustPercent:
            guard let volume else { return "当前输出设备没有确认音量，操作未完成。" }
            message = result.changed ? "系统音量已调到\(volume)。" : "系统音量已是\(volume)。"
        case .setMuted(let muted):
            guard state.isMuted == muted else { return "当前输出设备没有确认静音状态，操作未完成。" }
            if muted { return result.changed ? "系统已静音。" : "系统已经处于静音状态。" }
            message = result.changed ? "系统已取消静音。" : "系统当前未静音。"
            if let volume { message += "音量为\(volume)。" }
        }
        if state.isMuted == true { message += "当前处于静音状态。" }
        if volume == "0%", state.isMuted != true { message += "当前音量为零。" }
        if command == .query, volume == nil, state.isMuted == nil {
            message += "HDMI 等数字输出通常需要在显示器或音箱上调节。"
        }
        return message
    }

    static func shouldSpeak(_ state: VolumeState, command: SystemVolumeCommand) -> Bool {
        // A spoken acknowledgement cannot be heard after muting or setting zero.
        if command == .setMuted(true) { return false }
        return state.isMuted != true && state.volumePercent != 0
    }
}
