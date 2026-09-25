import Testing
@testable import PathOS

/// Listening for noise without getting in the way of what you're listening to.
struct SoundSharingTests {
    /// Nothing playing: the microphone is free to use.
    @Test func quietPhoneListens() {
        #expect(SoundSceneRules.mayListen(otherAudioPlaying: false, headphonesOn: false))
    }

    /// Music in your earbuds goes on playing, and the phone's own microphone still listens.
    @Test func headphonesShareTheMicrophone() {
        #expect(SoundSceneRules.mayListen(otherAudioPlaying: true, headphonesOn: true))
    }

    /// Music on the phone's speaker: taking the microphone would interrupt it, and would only
    /// hear the music, so it stands aside.
    @Test func theSpeakerIsLeftAlone() {
        #expect(!SoundSceneRules.mayListen(otherAudioPlaying: true, headphonesOn: false))
    }
}
