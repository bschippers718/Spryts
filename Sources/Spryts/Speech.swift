import AppKit
import AVFoundation

/// Characters reading their replies aloud, each at its own pitch and pace. Off until turned on for a character.
@MainActor
final class SpeechOut {
    static let shared = SpeechOut()
    private let synth = AVSpeechSynthesizer()

    static func isOn(_ id: String) -> Bool { UserDefaults.standard.bool(forKey: "speak." + id) }

    static func set(_ on: Bool, for id: String) {
        UserDefaults.standard.set(on, forKey: "speak." + id)
        if !on { shared.stop() }
    }

    func finished(_ text: String, by sheet: CharacterSheet) {
        if SpeechOut.isOn(sheet.id) { say(text, as: sheet) }
    }

    func say(_ text: String, as sheet: CharacterSheet) {
        let spoken = SpeechOut.speakable(text)
        if spoken.isEmpty { return }
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = SpeechOut.voice
        // Smaller characters sound a little higher; brisk movers talk a little faster.
        // A made Spryt can be given a voice of its own.
        let voice = sheet.custom == true ? sheet.voice?.cleaned : nil
        utterance.pitchMultiplier = Float(voice?.pitch ?? min(1.45, max(0.8, 1 + (110 - sheet.look.height) / 110)))
        let pace = Float(voice?.pace ?? min(1.25, max(0.85, sheet.motion.tempo)))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * (0.9 + 0.12 * pace)
        synth.speak(utterance)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    /// The best English voice installed: premium, then enhanced, then the default.
    private static let voice: AVSpeechSynthesisVoice? = {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let local = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let ranked = english.sorted { a, b in
            if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
            return (a.language == local ? 0 : 1) < (b.language == local ? 0 : 1)
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    /// A reply as it should sound: no code, no markdown marks, and short enough to listen to.
    static func speakable(_ text: String) -> String {
        var out: [String] = []
        var inCode = false
        var skippedCode = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inCode.toggle()
                if inCode && !skippedCode {
                    out.append("The code is in the window.")
                    skippedCode = true
                }
                continue
            }
            if inCode || line.isEmpty || line.hasPrefix("|") { continue }
            var clean = line
            while clean.hasPrefix("#") || clean.hasPrefix(">") || clean.hasPrefix("- ") || clean.hasPrefix("* ") {
                clean = String(clean.dropFirst(clean.hasPrefix("- ") || clean.hasPrefix("* ") ? 2 : 1))
                    .trimmingCharacters(in: .whitespaces)
            }
            out.append(clean)
        }
        var spoken = out.joined(separator: " ")
        spoken = spoken.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        for mark in ["**", "__", "`", "*"] { spoken = spoken.replacingOccurrences(of: mark, with: "") }
        if spoken.count > 700 {
            let cut = spoken.prefix(700)
            if let end = cut.lastIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
                spoken = String(cut[...end])
            } else {
                spoken = String(cut)
            }
        }
        return spoken.trimmingCharacters(in: .whitespaces)
    }

    /// Starts macOS Dictation in whatever text field has the focus. Needs no permission from Spryts.
    static func dictate() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
        }
    }
}
