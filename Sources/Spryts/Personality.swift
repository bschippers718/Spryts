import AppKit

/// Small differences in expression, shared by movement and neighbourly chatter.
/// These shape existing moments; they never schedule extra activity or grant a role capabilities.
struct SprytPersonality {
    let greetingGesture: String
    let microGestures: [Int]
    /// Angular frequency for the resting breath, in radians per second.
    let breathingRate: CGFloat
    /// Amplitude multiplier for conversational body language.
    let talkingEnergy: CGFloat

    private let openers: [String]
    private let answers: [String]

    init(role: String?) {
        // Keep at least seven gestures per role so avoiding the last five still leaves variety.
        switch role ?? "generalist" {
        case "generalist":
            greetingGesture = "wave"
            microGestures = [1, 2, 3, 6, 7, 8, 11]
            breathingRate = 2.3
            talkingEnergy = 1.05
            openers = [
                "Psst, {name}. What's caught your eye?",
                "{name}! Care for a tiny adventure?",
                "Hey, {name}. Prime ledge you've got there.",
                "{name}, ever wonder what's behind the pixels?"
            ]
            answers = [
                "Ooh. I'm listening.",
                "You had me at hello.",
                "Tiny feet, excellent company.",
                "I like the way you think."
            ]
        case "coder":
            greetingGesture = "nod"
            microGestures = [1, 3, 4, 7, 9, 10, 12]
            breathingRate = 1.7
            talkingEnergy = 0.55
            openers = [
                "Hello, {name}. Room for a quiet neighbour?",
                "{name}. A perfectly reasonable place to stand.",
                "Sharing this ledge seems efficient, {name}.",
                "{name}, a pause. Sensible."
            ]
            answers = [
                "Agreed. Concisely.",
                "That seems reasonable.",
                "A good use of a quiet moment.",
                "I appreciate the company."
            ]
        case "writer":
            greetingGesture = "bow"
            microGestures = [1, 2, 3, 5, 6, 9, 12]
            breathingRate = 1.9
            talkingEnergy = 0.85
            openers = [
                "Ah, {name}. An entrance.",
                "{name}, a pause worth keeping.",
                "A little company, {name}? No speech required.",
                "{name}. The ledge has a certain poetry."
            ]
            answers = [
                "A lovely little interlude.",
                "Precisely the right note.",
                "Consider me charmed.",
                "I'll keep that line."
            ]
        case "coach":
            greetingGesture = "pump"
            microGestures = [1, 4, 5, 6, 7, 11, 12]
            breathingRate = 2.5
            talkingEnergy = 0.95
            openers = [
                "Easy lap, {name}? Your pace.",
                "{name}! There's room on the bench.",
                "Good to see you, {name}. Shake it out?",
                "{name}, even little legs get a breather."
            ]
            answers = [
                "I'm in. Easy pace.",
                "Rest is part of the rhythm.",
                "Good company, good energy.",
                "One little step at a time."
            ]
        case "forecaster":
            greetingGesture = "nod"
            microGestures = [1, 2, 3, 4, 8, 9, 11]
            breathingRate = 1.6
            talkingEnergy = 0.6
            openers = [
                "Hello, {name}. A little cloud watching?",
                "{name}, do you have a favourite cloud shape?",
                "A quiet moment, {name}? Let it drift.",
                "{name}, I'm partial to a gentle breeze."
            ]
            answers = [
                "A little calm suits me.",
                "Happy to drift alongside you.",
                "Cloud watching is better with company.",
                "No hurry. We can take a moment."
            ]
        default:
            // Homemade and unknown roles stay companions, with no specialist identity.
            greetingGesture = "wave"
            microGestures = [1, 2, 3, 4, 5, 8, 9]
            breathingRate = 2.0
            talkingEnergy = 0.75
            openers = [
                "Hey, {name}. Glad you're here.",
                "{name}, mind if I sit nearby?",
                "A little company, {name}?",
                "Hello, {name}. This is a cosy corner."
            ]
            answers = [
                "There's always room for you.",
                "Happy to be here with you.",
                "A quiet moment together sounds nice.",
                "Thanks for stopping by."
            ]
        }
    }

    func opener(to name: String) -> String {
        (openers.randomElement() ?? "Hello, {name}.")
            .replacingOccurrences(of: "{name}", with: name)
    }

    var answer: String {
        answers.randomElement() ?? "Happy to see you."
    }
}
