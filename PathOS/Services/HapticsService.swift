import Observation
import UIKit

/// Scales alert feedback to the sound scene: strong double pulses in noisy transit,
/// gentle and silent (visual-only) in quiet spaces.
@Observable
final class HapticsService {
    var isAdaptive = true
    private(set) var scene: SoundScene = .unknown

    func update(scene: SoundScene) {
        self.scene = scene
    }

    /// Whether alerts should make sound, or stay visual-only.
    var shouldPlaySound: Bool {
        !(isAdaptive && scene == .quiet)
    }

    func alert() {
        guard isAdaptive else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        switch scene {
        case .noisy:
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.impactOccurred(intensity: 1)
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                generator.impactOccurred(intensity: 1)
            }
        case .quiet:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.4)
        case .moderate, .unknown:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    func tick() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
