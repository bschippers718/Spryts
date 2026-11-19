import CoreGraphics
import Foundation

// How a Spryt listens. While you type to it, it reads the words on this Mac (nothing is sent anywhere) and its
// body answers: it leans in, nods at the pace of your typing, follows the line with its eyes, tilts its head at a
// question, winces with you at bad news, bounces at good news, and does the move you ask for when you press Return.
// Everything here is a pure function of the text and the clock, so it can be checked without the app.

/// What a line of text feels like, in the few ways a small body can show.
enum Feeling: String, CaseIterable {
    case neutral, greeting, farewell, thanks, praise, love, joy, laughing, sad, worried, frustrated, urgent, sleepy
}

/// What the Spryt took from the words.
struct Reading: Equatable {
    var feeling = Feeling.neutral
    var strength: CGFloat = 0       // 0...1, how strongly it came across
    var question = false
    var shouting = false            // mostly capitals
    var trailingOff = false         // ends in an ellipsis
    var excitement: CGFloat = 0     // 0...1 from exclamation marks
    var move: String?               // a move it was asked to do, from Moves.library
    var named = false               // it was called by name
}

enum Listening {
    // MARK: Reading the words

    private static let negators: Set<String> = ["not", "no", "never", "dont", "doesnt", "didnt", "isnt", "wasnt", "arent",
                                                "cant", "wont", "without", "stop", "hardly", "barely"]

    /// Single words. A negator just before one turns it around ("not happy", "no problem").
    private static let words: [Feeling: [String: CGFloat]] = [
        .greeting: ["hi": 1, "hello": 1, "hey": 1, "hiya": 1, "howdy": 1, "yo": 0.7, "morning": 0.8, "gm": 0.8, "sup": 0.7, "greetings": 1],
        .farewell: ["bye": 1, "goodbye": 1, "goodnight": 1, "gn": 0.8, "cya": 1, "later": 0.3, "farewell": 1, "ttyl": 1],
        .thanks: ["thanks": 1, "thank": 1, "thx": 1, "ty": 0.8, "cheers": 0.7, "appreciate": 1, "appreciated": 1, "grateful": 1],
        .praise: ["great": 0.8, "awesome": 1, "amazing": 1, "perfect": 1, "brilliant": 1, "excellent": 1, "nice": 0.7,
                  "good": 0.5, "cool": 0.6, "wonderful": 1, "fantastic": 1, "incredible": 1, "beautiful": 0.9, "nailed": 1,
                  "impressive": 1, "bravo": 1, "solid": 0.6, "superb": 1, "lovely": 0.8, "clever": 0.8, "genius": 1],
        .love: ["love": 1, "adore": 1, "heart": 0.6, "hug": 0.9, "hugs": 0.9, "xoxo": 1, "cute": 0.8, "sweet": 0.6],
        .joy: ["yay": 1, "woohoo": 1, "woo": 0.9, "hooray": 1, "hurray": 1, "excited": 1, "happy": 0.9, "thrilled": 1,
               "celebrate": 1, "congrats": 1, "congratulations": 1, "shipped": 0.9, "launched": 0.9, "won": 0.9, "finally": 0.6,
               "delighted": 1, "stoked": 1, "pumped": 1, "yes": 0.3, "yesss": 1, "wow": 0.8],
        .laughing: ["haha": 1, "hahaha": 1, "hahahaha": 1, "lol": 0.9, "lmao": 1, "rofl": 1, "hehe": 0.8, "funny": 0.7, "hilarious": 1],
        .sad: ["sad": 1, "unhappy": 1, "upset": 0.9, "lonely": 1, "miss": 0.6, "lost": 0.6, "crying": 1, "cried": 1, "hurt": 0.8,
               "hurts": 0.8, "heartbroken": 1, "depressed": 1, "down": 0.2, "rough": 0.7, "tough": 0.6, "awful": 0.9,
               "terrible": 0.9, "sorry": 0.5, "disappointed": 0.9, "failed": 0.7, "grief": 1, "died": 1],
        .worried: ["worried": 1, "worry": 0.9, "anxious": 1, "nervous": 1, "scared": 1, "afraid": 1, "stressed": 1, "stress": 0.8,
                   "overwhelmed": 1, "panic": 1, "unsure": 0.7, "stuck": 0.7, "confused": 0.7, "help": 0.3],
        .frustrated: ["ugh": 1, "argh": 1, "annoying": 1, "annoyed": 1, "broken": 0.8, "hate": 1, "frustrated": 1,
                      "frustrating": 1, "useless": 1, "stupid": 0.9, "damn": 0.9, "wtf": 1, "crap": 0.9, "wrong": 0.5,
                      "angry": 1, "mad": 0.8, "furious": 1, "sucks": 1, "ridiculous": 0.8, "again": 0.3, "crashed": 0.8, "bug": 0.3],
        .urgent: ["urgent": 1, "asap": 1, "now": 0.3, "quick": 0.7, "quickly": 0.8, "hurry": 1, "immediately": 1, "deadline": 0.9,
                  "emergency": 1, "fast": 0.6, "rush": 0.9, "late": 0.5],
        .sleepy: ["tired": 0.9, "sleepy": 1, "exhausted": 1, "yawn": 1, "zzz": 1, "drained": 0.9, "bedtime": 1, "knackered": 1],
    ]

    /// Longer turns of phrase, matched whole.
    private static let phrases: [(Feeling, CGFloat, String)] = [
        (.greeting, 1, "good morning"), (.greeting, 1, "good afternoon"), (.greeting, 1, "good evening"), (.greeting, 0.9, "whats up"),
        (.farewell, 1, "good night"), (.farewell, 1, "see you"), (.farewell, 1, "see ya"), (.farewell, 1, "talk later"),
        (.farewell, 1, "signing off"), (.farewell, 0.9, "im off"),
        (.thanks, 1, "thank you"), (.thanks, 1, "much appreciated"), (.thanks, 1, "you rock"),
        (.praise, 1, "good job"), (.praise, 1, "great job"), (.praise, 1, "nice work"), (.praise, 1, "well done"),
        (.praise, 1, "nailed it"), (.praise, 1, "love it"), (.praise, 1, "youre the best"), (.praise, 0.9, "looks good"),
        (.praise, 0.8, "not bad"),
        (.love, 1, "love you"), (.love, 1, "miss you"),
        (.joy, 1, "we did it"), (.joy, 1, "i did it"), (.joy, 1, "it works"), (.joy, 1, "it worked"), (.joy, 1, "lets go"),
        (.joy, 1, "good news"), (.joy, 1, "cant wait"), (.joy, 0.9, "so happy"),
        (.sad, 1, "bad day"), (.sad, 1, "rough day"), (.sad, 1, "long day"), (.sad, 1, "bad news"), (.sad, 1, "not great"),
        (.sad, 1, "not good"), (.sad, 0.9, "feeling down"), (.sad, 1, "passed away"),
        (.worried, 1, "not sure"), (.worried, 1, "freaking out"), (.worried, 1, "what if"), (.worried, 0.8, "i dont know"),
        (.frustrated, 1, "doesnt work"), (.frustrated, 1, "not working"), (.frustrated, 1, "still broken"),
        (.frustrated, 1, "fed up"), (.frustrated, 1, "come on"), (.frustrated, 1, "give up"), (.frustrated, 1, "so slow"),
        (.urgent, 1, "right now"), (.urgent, 1, "right away"), (.urgent, 1, "no time"), (.urgent, 1, "running late"),
        (.urgent, 1, "as soon as"),
        (.sleepy, 1, "need sleep"), (.sleepy, 1, "so tired"), (.sleepy, 1, "need coffee"), (.sleepy, 0.9, "long night"),
    ]

    private static let symbols: [(Feeling, CGFloat, [String])] = [
        (.joy, 1, [":)", ":-)", ":D", "😀", "😃", "😄", "😁", "🙂", "😊", "🎉", "🥳", "🙌", "✨", "👍"]),
        (.laughing, 1, ["😂", "🤣", "😆", "xD", "XD"]),
        (.love, 1, ["❤", "😍", "🥰", "💕", "💖", "😘", "<3"]),
        (.sad, 1, [":(", ":-(", ":'(", "😢", "😭", "😞", "😔", "🥺", "💔"]),
        (.worried, 1, ["😟", "😰", "😬", "😨", "🫠"]),
        (.frustrated, 1, ["😡", "🤬", "😤", "🙄", "😠"]),
        (.sleepy, 1, ["😴", "🥱", "💤"]),
        (.greeting, 1, ["👋"]),
        (.thanks, 1, ["🙏"]),
    ]

    private static let asking: Set<String> = ["who", "what", "when", "where", "why", "how", "which", "can", "could", "would",
                                              "should", "is", "are", "do", "does", "did", "will", "whats", "hows"]

    /// Words that ask for a move, longest first, and the move in the catalogue each one means.
    private static let moveWords: [(String, String)] = [
        ("jumping jacks", "jacks"), ("jumping jack", "jacks"), ("victory lap", "lap"), ("high kicks", "kicks"),
        ("high kick", "kicks"), ("backflip", "flip"), ("somersault", "flip"), ("moonwalk", "moonwalk"), ("cartwheel", "flip"),
        ("jump", "jump"), ("hop", "jump"), ("flip", "flip"), ("spin", "spin"), ("twirl", "twirl"), ("pirouette", "twirl"),
        ("dance", "dance"), ("boogie", "dance"), ("wave", "wave"), ("bow", "bow"), ("wiggle", "wiggle"), ("shimmy", "shimmy"),
        ("stretch", "stretch"), ("flex", "flex"), ("stomp", "stomp"), ("kick", "kicks"), ("swing", "swing"), ("lap", "lap"),
    ]
    private static let moveCues: Set<String> = ["do", "please", "lets", "go", "now"]
    private static let canYou: Set<String> = ["can", "could", "would", "will"]
    /// "Jump to the next section" is about the work, not the Spryt.
    private static let notAMove: Set<String> = ["to", "into", "through", "over", "ahead", "start", "back", "in", "on", "up", "down",
                                                "off", "out", "the", "this", "that", "of", "from", "by", "a", "an", "it", "my", "goal", "goals", "chart", "state"]

    /// Lower-case words with punctuation and apostrophes removed: "Don't!" becomes "dont".
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                word.append(ch)
            } else if ch == "'" || ch == "’" {
                continue
            } else if !word.isEmpty {
                out.append(word)
                word = ""
            }
        }
        if !word.isEmpty { out.append(word) }
        return out
    }

    /// The sentence being written right now: the last one with any letters in it.
    static func focus(_ text: String) -> String {
        let tail = String(text.suffix(280))
        var sentences: [String] = []
        var current = ""
        for ch in tail {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" || ch == "…" {
                // Keep a run of marks ("?!", "...") with the sentence it ends.
                continue
            }
            if let previous = current.dropLast().last, ".!?\n…".contains(previous) {
                let finished = String(current.dropLast())
                if finished.contains(where: { $0.isLetter }) { sentences.append(finished) }
                current = String(ch)
            }
        }
        if current.contains(where: { $0.isLetter }) || sentences.isEmpty { sentences.append(current) }
        return sentences.last ?? tail
    }

    /// Reads a draft or a sent message. `name` is the Spryt's own name, so "Pip, do a flip" counts as asking.
    static func read(_ text: String, name: String = "") -> Reading {
        var reading = Reading()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return reading }
        let sentence = focus(trimmed)
        let said = tokens(sentence)
        let all = tokens(String(trimmed.suffix(280)))
        let own = tokens(name).first ?? ""

        // Marks and volume.
        let ending = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        reading.question = ending.hasSuffix("?") || ending.hasSuffix("?!") || (said.count >= 3 && asking.contains(said[0]) && !ending.hasSuffix("."))
        reading.trailingOff = trimmed.hasSuffix("...") || trimmed.hasSuffix("…")
        reading.excitement = min(1, CGFloat(sentence.filter { $0 == "!" }.count) / 3)
        let letters = sentence.filter { $0.isLetter }
        reading.shouting = letters.count >= 6 && CGFloat(letters.filter { $0.isUppercase }.count) / CGFloat(letters.count) > 0.7
        reading.named = !own.isEmpty && all.contains(own)

        // Feeling: the current sentence counts in full, what came before it at a third.
        var scores: [Feeling: CGFloat] = [:]
        func tally(_ list: [String], weight: CGFloat) {
            for (index, word) in list.enumerated() {
                let negated = (max(0, index - 2)..<index).contains { negators.contains(list[$0]) }
                for (feeling, table) in words {
                    guard let value = table[word] else { continue }
                    if !negated {
                        scores[feeling, default: 0] += value * weight
                    } else if feeling == .praise || feeling == .joy || feeling == .love {
                        scores[.sad, default: 0] += value * weight * 0.7        // "not happy"
                    } else if feeling == .sad || feeling == .worried || feeling == .frustrated {
                        scores[.praise, default: 0] += value * weight * 0.4     // "no problem", "not bad"
                    }
                }
            }
            let joined = " " + list.joined(separator: " ") + " "
            for (feeling, value, phrase) in phrases where joined.contains(" " + phrase + " ") {
                scores[feeling, default: 0] += value * weight * 1.5              // a whole phrase outweighs its parts
            }
        }
        tally(said, weight: 1)
        if all.count > said.count { tally(Array(all.dropLast(said.count)), weight: 0.33) }
        for (feeling, value, marks) in symbols where marks.contains(where: { trimmed.contains($0) }) {
            scores[feeling, default: 0] += value * 1.2
        }
        // "Hi" is hello only at the start of what you are saying, and it fades as the sentence turns into a request.
        if let hello = scores[.greeting] {
            let opening = " " + said.prefix(3).joined(separator: " ") + " "
            let opens = (said.first.map { words[.greeting]?[$0] != nil } ?? false) || trimmed.contains("👋")
                || phrases.contains { $0.0 == .greeting && opening.contains(" " + $0.2 + " ") }
            scores[.greeting] = opens ? hello * (said.count <= 3 ? 1 : 3 / CGFloat(said.count)) : nil
        }
        if let best = scores.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue) }), best.value >= 0.4 {
            reading.feeling = best.key
            reading.strength = min(1, 0.4 + best.value * 0.3 + reading.excitement * 0.25 + (reading.shouting ? 0.2 : 0))
        } else if reading.excitement > 0 {
            reading.feeling = .joy
            reading.strength = 0.3 + 0.4 * reading.excitement
        }

        reading.move = request(in: said, name: own)
        return reading
    }

    /// The move this sentence asks the Spryt to do, if it really is asking.
    private static func request(in said: [String], name: String) -> String? {
        if said.isEmpty || said.count > 14 { return nil }
        for (phrase, move) in moveWords {
            let parts = phrase.split(separator: " ").map(String.init)
            guard let start = said.indices.first(where: { index in
                index + parts.count <= said.count && Array(said[index..<(index + parts.count)]) == parts
            }) else { continue }
            let before = Array(said[max(0, start - 4)..<start])
            let after = start + parts.count < said.count ? said[start + parts.count] : ""
            if before.contains(where: { negators.contains($0) }) { return nil }      // "don't jump"
            if notAMove.contains(after) { continue }                                  // "jump to the next section"
            let previous = before.last
            let direct = previous == nil && said.count <= 6                           // "Jump!", "dance for me"
            let afterCue = previous.map { moveCues.contains($0) || (!name.isEmpty && $0 == name) } ?? false   // "please dance"
            let afterArticle = ["a", "the", "your", "some", "little"].contains(previous ?? "")
                && before.contains(where: { moveCues.contains($0) || $0 == "me" || $0 == "us" || $0 == "give" })   // "do a flip", "give us a twirl"
            let afterYou = previous == "you" && before.contains(where: { canYou.contains($0) })   // "can you jump"
            let called = !name.isEmpty && said.contains(name) && said.count <= 6       // "Pip, flip"
            if direct || afterCue || afterArticle || afterYou || called || said.count <= 2 { return move }
        }
        return nil
    }

    // MARK: The body's answer

    /// The offsets a listening body adds to its standing pose, and the face it wears while it listens.
    struct Cue: Equatable {
        var attention: CGFloat = 0      // 0...1: how far it has turned to face you
        var lean: CGFloat = 0           // forward is positive
        var sway: CGFloat = 0           // side to side
        var headTilt: CGFloat = 0
        var headPitch: CGFloat = 0
        var bounce: CGFloat = 0         // points off the ground
        var squash: CGFloat = 1
        var armsOut: CGFloat = 0
        var armsForward: CGFloat = 0
        var elbows: CGFloat = 0
        var handUp: CGFloat = 0         // right hand rising, ready to wave
        var smile: CGFloat = 0.25
        var mouth: CGFloat = 0
        var brow: CGFloat = 0           // positive is stern, negative is sorry
        var browLift: CGFloat = 0
        var browCock: CGFloat = 0
        var blush: CGFloat = 0
        var eyeOpen: CGFloat = 1
        var lookX: CGFloat = 0
        var lookY: CGFloat = 0
    }

    /// The cue for this instant. `energy` is how demonstrative this Spryt is (a writer is quieter than a coach).
    static func cue(for ear: Ear, at t: CGFloat, energy: CGFloat) -> Cue {
        var c = Cue()
        let a = min(1, max(0, ear.level))
        if a <= 0.001 { return c }
        let k = min(1.3, max(0.4, energy))
        let r = ear.reading
        let s = r.strength * a * k
        let pace = ear.pace

        // Always, while you are writing to it: turned to you, leaning in, nodding at the speed you type,
        // eyes crossing the line as it fills and dropping back at the end of it.
        c.attention = a
        c.lean = (0.09 + 0.05 * pace) * a
        c.headPitch = 0.06 * pace * a * sin(t * (5 + 7 * pace))
        c.lookY = -0.35 * a
        c.lookX = (CGFloat(ear.length % 42) / 42 - 0.5) * 0.7 * a
        c.smile = 0.25 + 0.15 * a
        c.browLift = 0.2 * a
        if ear.quiet > 2.5 {
            // You have stopped to think. It waits, in no hurry.
            c.headTilt += 0.08 * a * sin(t * 0.9)
            c.lookY = -0.1 * a
            c.lookX = 0
        }

        if r.question {
            c.headTilt += 0.2 * a
            c.browLift += 0.4 * a
            c.browCock = a
        }
        if r.trailingOff {
            c.headTilt += 0.12 * a
            c.lean += 0.03 * a
        }
        if r.named {
            c.browLift += 0.3 * a
            c.eyeOpen = max(c.eyeOpen, 1 + 0.1 * a)
        }
        if r.move != nil {
            // It knows what is coming and can hardly wait.
            c.bounce += 2 * a * k * abs(sin(t * 8))
            c.armsOut += 0.25 * a
            c.smile = max(c.smile, 0.9)
        }
        if r.excitement > 0 {
            let e = r.excitement * a * k
            c.bounce += 2.5 * e * abs(sin(t * 9))
            c.smile = max(c.smile, 0.5 + 0.4 * e)
        }

        switch r.feeling {
        case .neutral:
            break
        case .greeting, .farewell:
            c.handUp = (r.feeling == .greeting ? 0.55 : 0.4) * s
            c.smile = max(c.smile, 0.9)
            c.headTilt += r.feeling == .farewell ? 0.1 * s : 0
        case .thanks:
            c.blush = s
            c.smile = 1
            c.headPitch += 0.1 * s
            c.sway = 0.06 * s * sin(t * 3)
        case .praise:
            c.blush = 0.7 * s
            c.smile = 1
            c.bounce += 2 * s * abs(sin(t * 7))
            c.sway = 0.08 * s * sin(t * 5)
        case .love:
            c.blush = s
            c.smile = 1
            c.headTilt += 0.15 * s
            c.sway = 0.07 * s * sin(t * 2.6)
            c.armsForward += 0.3 * s
            c.elbows += 0.9 * s
        case .joy:
            c.bounce += 3 * s * abs(sin(t * 8))
            c.armsOut += 0.5 * s
            c.smile = 1
            c.mouth = 0.25 * s
        case .laughing:
            c.bounce += 3.5 * s * abs(sin(t * 11))
            c.squash = 1 - 0.04 * s * abs(sin(t * 11))
            c.lean -= 0.06 * s
            c.smile = 1
            c.mouth = 0.5 * s
            c.eyeOpen = 1 - 0.5 * s
        case .sad:
            c.lean += 0.08 * s
            c.headTilt += 0.16 * s
            c.smile = 0.25 - 0.5 * s
            c.brow = -0.5 * s
            c.browLift += 0.5 * s
            c.armsForward += 0.45 * s
            c.elbows += 1.1 * s
            c.bounce -= 1.5 * s
        case .worried:
            c.lean += 0.06 * s
            c.headTilt += 0.1 * s
            c.smile = 0.25 - 0.35 * s
            c.brow = -0.35 * s
            c.browLift += 0.6 * s
            c.armsForward += 0.3 * s
            c.elbows += 0.8 * s
            c.lookX += 0.12 * s * sin(t * 6)
        case .frustrated:
            // A wince on your behalf, then it holds still and hears you out.
            c.squash = 1 - 0.03 * s
            c.lean -= 0.03 * s
            c.smile = 0.25 - 0.4 * s
            c.mouth = 0.1 * s
            c.brow = -0.25 * s
            c.browLift += 0.3 * s
            c.headPitch = 0.05 * s * sin(t * 2.5)
        case .urgent:
            c.bounce += 2 * s + 1.5 * s * abs(sin(t * 12))
            c.lean += 0.08 * s
            c.armsForward += 0.3 * s
            c.elbows += 1.2 * s
            c.brow = 0.3 * s
            c.eyeOpen = max(c.eyeOpen, 1 + 0.12 * s)
            c.smile = 0.1
        case .sleepy:
            c.eyeOpen = 1 - 0.45 * s
            c.headTilt += 0.12 * s
            let yawn = max(0, sin(t * 0.8))
            c.mouth = 0.5 * s * yawn * yawn * yawn * yawn
            c.lean -= 0.02 * s
        }

        if r.shouting {
            c.lean -= 0.05 * a
            c.eyeOpen = max(c.eyeOpen, 1.12)
        }
        // Brief things, layered last: a paste or a shout startles it, deleting makes it wonder, clearing the box lets it breathe out.
        let jolt = ear.surprise * a
        c.lean -= 0.16 * jolt
        c.eyeOpen += 0.25 * jolt
        c.armsOut += 0.5 * jolt
        c.browLift += 0.8 * jolt
        c.mouth = max(c.mouth, 0.4 * jolt)
        let wonder = ear.doubt * a
        c.headTilt -= 0.16 * wonder
        c.browCock = max(c.browCock, wonder)
        c.squash *= 1 - 0.03 * ear.letGo

        c.lean = min(0.3, max(-0.25, c.lean))
        c.headTilt = min(0.4, max(-0.4, c.headTilt))
        c.bounce = min(9, max(-3, c.bounce))
        c.eyeOpen = min(1.25, max(0.3, c.eyeOpen))
        c.browLift = min(1, c.browLift)
        c.smile = min(1, max(-0.6, c.smile))
        c.blush = min(1, c.blush)
        c.mouth = min(1, c.mouth)
        c.handUp = min(1, c.handUp)
        return c
    }

    // MARK: When you press Return

    /// What the body does the moment a message is sent, before the answer starts to arrive.
    enum Response: Equatable {
        case nothing
        case move(String)               // one from Moves.library
        case gesture(String, emote: String?)
        case hop(emote: String?)
    }

    static func response(to reading: Reading) -> Response {
        if let move = reading.move { return .move(move) }
        switch reading.feeling {
        case .greeting, .farewell:
            return .gesture("wave", emote: nil)
        case .thanks:
            return .gesture("bow", emote: "♥")
        case .praise:
            return reading.strength > 0.75 ? .hop(emote: "♥") : .gesture("wiggle", emote: "♥")
        case .love:
            return .gesture("wiggle", emote: "♥")
        case .joy:
            return reading.strength > 0.6 ? .hop(emote: "♪") : .gesture("pump", emote: "♪")
        case .laughing:
            return .gesture("shimmy", emote: "♪")
        case .sad, .worried:
            return .gesture("nod", emote: nil)
        case .frustrated:
            return .gesture("nod", emote: "…")
        case .urgent:
            return .gesture("nod", emote: "!")
        case .sleepy:
            return .gesture("stretch", emote: nil)
        case .neutral:
            if reading.question { return .gesture("think", emote: "?") }
            return reading.excitement > 0.6 ? .hop(emote: "!") : .nothing
        }
    }
}

/// What the Spryt has heard so far, and how it is taking it. Fed each time the draft changes; ticked every frame.
struct Ear: Equatable {
    private(set) var reading = Reading()
    private(set) var level: CGFloat = 0        // 0 not listening ... 1 all ears
    private(set) var pace: CGFloat = 0         // 0...1, how fast you are typing
    private(set) var surprise: CGFloat = 0     // a paste, or sudden capitals
    private(set) var doubt: CGFloat = 0        // you are deleting
    private(set) var letGo: CGFloat = 0        // the box was just emptied
    private(set) var length = 0
    private(set) var quiet: CGFloat = 99       // seconds since the draft last changed
    private(set) var sent = ""                 // what was in the box when it emptied
    private(set) var sinceEmptied: CGFloat = 99
    private var text = ""

    mutating func heard(_ draft: String, name: String) {
        if draft == text { return }
        let count = draft.count
        let delta = count - length
        if draft.isEmpty {
            sent = text
            sinceEmptied = 0
            letGo = 1
        } else if delta >= 12 {
            surprise = 1                                        // pasted in one go
        } else if delta > 0 {
            pace = min(1, pace + 0.16 * CGFloat(delta))
        } else if delta < 0 {
            doubt = min(1, doubt + 0.18 * CGFloat(-delta))
        }
        let before = reading
        reading = draft.isEmpty ? Reading() : Listening.read(draft, name: name)
        if reading.shouting && !before.shouting { surprise = max(surprise, 0.8) }
        text = draft
        length = count
        quiet = 0
    }

    /// `attending` is whether its chat is open in front of you.
    mutating func tick(_ dt: CGFloat, attending: Bool) {
        quiet += dt
        sinceEmptied += dt
        pace *= exp(-dt / 0.7)
        surprise *= exp(-dt / 0.9)
        doubt *= exp(-dt / 1.2)
        letGo *= exp(-dt / 0.8)
        var target: CGFloat = 0
        if length > 0 {
            if quiet < 2.5 { target = 1 } else if attending { target = quiet < 20 ? 0.6 : 0.25 }
        }
        level += (target - level) * min(1, dt * 5)
        if level < 0.001 { level = 0 }
    }

    /// The message that was just sent, once, if the box emptied a moment ago.
    mutating func takeSent() -> String? {
        guard sinceEmptied < 1.5, !sent.isEmpty else { return nil }
        let said = sent
        sent = ""
        return said
    }
}
