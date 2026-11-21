import CoreGraphics
import Foundation

@main
struct ListeningChecks {
    static var checks = 0
    static var failures: [String] = []

    static func expect(_ condition: Bool, _ why: String) {
        checks += 1
        if condition { print("PASS  " + why) } else { failures.append(why); print("FAIL  " + why) }
    }

    static func feels(_ text: String, _ feeling: Feeling, name: String = "Pip") {
        let got = Listening.read(text, name: name)
        expect(got.feeling == feeling, "\"\(text)\" reads as \(feeling.rawValue)" + (got.feeling == feeling ? "" : " (got \(got.feeling.rawValue))"))
    }

    static func asks(_ text: String, _ move: String?, name: String = "Pip") {
        let got = Listening.read(text, name: name).move
        expect(got == move, "\"\(text)\" asks for \(move ?? "no move")" + (got == move ? "" : " (got \(got ?? "none"))"))
    }

    /// Types a line one key at a time at a steady speed, ticking the clock between keys.
    static func type(_ text: String, into ear: inout Ear, perSecond: Double = 6) {
        var draft = ""
        for ch in text {
            draft.append(ch)
            ear.heard(draft, name: "Pip")
            var waited = 0.0
            while waited < 1 / perSecond {
                ear.tick(1.0 / 60, attending: true)
                waited += 1.0 / 60
            }
        }
    }

    static func main() {
        // What the words feel like.
        feels("hi", .greeting)
        feels("Hello Pip!", .greeting)
        feels("good morning", .greeting)
        feels("thank you so much", .thanks)
        feels("great job!", .praise)
        feels("not bad at all", .praise)
        feels("I love this", .love)
        feels("we did it!!!", .joy)
        feels("hahaha that's hilarious", .laughing)
        feels("I had a rough day", .sad)
        feels("I'm not happy with this", .sad)
        feels("I'm worried about the launch", .worried)
        feels("ugh this is still broken", .frustrated)
        feels("I need this asap", .urgent)
        feels("so tired today", .sleepy)
        feels("good night", .farewell)
        feels("ok see you tomorrow", .farewell)
        feels("Summarise the attached report in three bullets", .neutral)
        feels("scroll down and open the settings file", .neutral)
        feels("😂", .laughing)
        feels("that went badly :(", .sad)
        expect(Listening.read("hey can you fix the login screen in the settings page").feeling != .greeting,
               "a greeting fades once the sentence becomes a request")
        feels("I had a rough day. But we shipped it!", .joy)
        feels("I had a rough day :(. But we shipped it!", .joy)
        feels("That worked. 😂", .laughing)
        feels("We shipped it! But now I'm exhausted", .sleepy)
        feels("whoa no way!", .surprised)
        feels("🤯", .surprised)
        feels("hmm that's interesting", .curious)
        feels("🤔", .curious)
        expect(Listening.read("we did it!!!").strength > Listening.read("we did it").strength, "exclamation marks make it stronger")

        // Marks and volume.
        expect(Listening.read("what time is it?").question, "a question mark is a question")
        expect(Listening.read("can you summarise this").question, "so is a sentence that opens by asking")
        expect(!Listening.read("This is fine.").question, "a statement is not")
        let shout = Listening.read("THIS IS BROKEN AGAIN")
        expect(shout.shouting && shout.feeling == .frustrated, "capitals are shouting")
        expect(!Listening.read("OK").shouting, "two capitals are not")
        expect(Listening.read("well...").trailingOff && Listening.read("well…").trailingOff, "an ellipsis trails off")
        expect(Listening.read("pip are you there", name: "Pip").named && !Listening.read("are you there", name: "Pip").named, "it knows its own name")
        expect(Listening.read("") == Reading() && Listening.read("   \n") == Reading(), "nothing typed reads as nothing")

        // Being asked to move, and not mistaking work for a request.
        asks("do a flip", "flip")
        asks("jump!", "jump")
        asks("Pip, dance", "dance")
        asks("can you do a backflip", "flip")
        asks("please dance for me", "dance")
        asks("can you jump", "jump")
        asks("do jumping jacks", "jacks")
        asks("moonwalk", "moonwalk")
        asks("let's dance", "dance")
        asks("show me your dance", "dance")
        asks("give us a twirl", "twirl")
        asks("take a bow", "bow")
        asks("do a triple hop", "hops")
        asks("do a back flip", "flip")
        asks("frontflip!", "flip")
        asks("take a jump in conversion", nil)
        asks("don't jump", nil)
        asks("please do not dance", nil)
        asks("jump to the next section", nil)
        asks("spin up a server for staging", nil)
        asks("the funnel had a big jump in conversion last week", nil)
        asks("kick off the build", nil)
        asks("flip the image horizontally", nil)
        asks("wave of new signups today", nil)
        asks("write a function that makes the sprite jump when space is pressed", nil)

        // Listening while you type.
        var ear = Ear()
        expect(Listening.cue(for: ear, at: 1, energy: 1) == Listening.Cue(), "silent box, still body")
        type("I think we should", into: &ear)
        expect(ear.level > 0.9 && ear.pace > 0.4 && ear.length == 17, "typing brings it to full attention")
        let attentive = Listening.cue(for: ear, at: 1, energy: 1)
        expect(attentive.attention > 0.9 && attentive.lean > 0.08 && attentive.lookY < 0, "it turns to you, leans in and looks at the line")
        var slow = Ear()
        type("I think we should", into: &slow, perSecond: 1.5)
        expect(slow.pace < ear.pace, "it nods faster when you type faster")
        let early = Listening.cue(for: ear, at: 1, energy: 1).lookX
        type(" ship this on Friday", into: &ear)
        expect(Listening.cue(for: ear, at: 1, energy: 1).lookX != early, "its eyes move along the line as it grows")
        for _ in 0..<240 { ear.tick(1.0 / 60, attending: true) }
        expect(ear.level > 0.5 && ear.level < 0.7 && ear.pace < 0.05, "when you pause it waits, still listening")
        for _ in 0..<240 { ear.tick(1.0 / 60, attending: false) }
        expect(ear.level < 0.05, "with its chat closed it goes back to its own business")

        var pasted = Ear()
        pasted.heard("Here is a long paragraph pasted in one go", name: "Pip")
        expect(pasted.surprise == 1, "a paste startles it")
        var prefilled = Ear()
        prefilled.heard("Give me five opening lines for a piece about ", name: "Pip", programmatic: true)
        expect(prefilled.surprise == 0, "a quick-action prefill does not startle it")
        var deleting = Ear()
        type("this is wrong", into: &deleting)
        deleting.heard("this is", name: "Pip")
        expect(deleting.doubt > 0.5, "deleting makes it wonder")
        var sending = Ear()
        type("do a flip", into: &sending)
        sending.heard("", name: "Pip")
        expect(sending.takeSent() == "do a flip" && sending.takeSent() == nil, "it catches what was sent, once")
        for _ in 0..<120 { sending.tick(1.0 / 60, attending: true) }
        expect(sending.level < 0.01 && sending.reading == Reading(), "and settles once the box is empty")

        // Integrated nod phase stays smooth even after long uptime (no t * variableFreq jitter).
        var longRun = Ear()
        type("typing smoothly after a long session", into: &longRun, perSecond: 8)
        var maxPitchStep: CGFloat = 0
        var prevPitch = Listening.cue(for: longRun, at: 1200, energy: 1).headPitch
        for step in 1...120 {
            longRun.tick(1.0 / 60, attending: true)
            let pitch = Listening.cue(for: longRun, at: 1200 + CGFloat(step) / 60, energy: 1).headPitch
            maxPitchStep = max(maxPitchStep, abs(pitch - prevPitch))
            prevPitch = pitch
        }
        expect(maxPitchStep < 0.03, "nodding stays smooth even at high uptime (max step \(maxPitchStep))")

        // Gaze follows the popup direction when above the character.
        var upward = Ear()
        type("looking up at the popup", into: &upward, perSecond: 10)
        expect(Listening.cue(for: upward, at: 1, energy: 1, gazeY: 0.42).lookY > 0.25, "looks up when the popup sits above it")
        var namedEar = Ear()
        type("hey Pip", into: &namedEar, perSecond: 10)
        expect(Listening.cue(for: namedEar, at: 1, energy: 1).twitch > 0.2, "calling its name perks its ears/antenna")

        // What the body does with it.
        func cue(_ text: String, at t: CGFloat = 0.2, energy: CGFloat = 1) -> Listening.Cue {
            var e = Ear()
            type(text, into: &e, perSecond: 12)
            return Listening.cue(for: e, at: t, energy: energy)
        }
        let plain = cue("the report is attached")
        expect(cue("is the report attached?").headTilt > plain.headTilt + 0.1, "a question tilts its head")
        expect(cue("I had a rough day").smile < 0.1 && cue("I had a rough day").brow < 0, "bad news takes the smile off its face")
        expect(cue("we did it!!!").bounce > 2 && cue("we did it!!!").smile == 1, "good news makes it bounce")
        expect(cue("thank you").blush > 0.4, "thanks makes it blush")
        expect(cue("hello").handUp > 0.2, "hello starts a wave")
        expect(cue("do a flip").bounce > 0.5, "it bounces when it sees a move coming")
        expect(cue("so tired").eyeOpen < 0.8, "tired words make its eyes heavy")
        expect(cue("THIS IS BROKEN AGAIN").lean < plain.lean, "shouting rocks it back")
        expect(cue("we did it!!!", energy: 0.4).bounce < cue("we did it!!!", energy: 1.2).bounce, "a quiet Spryt shows less than a lively one")
        var bounded = true
        for feeling in ["hi", "bye", "thank you", "great job!!!", "love you", "WE DID IT!!!", "hahaha 😂", "whoa no way 🤯",
                        "hmm interesting 🤔", "rough day :(", "so worried", "ugh BROKEN", "asap!!! hurry", "so tired...", "do a flip?!"] {
            for step in 0..<200 {
                let c = cue(feeling, at: CGFloat(step) * 0.05, energy: 1.3)
                let values = [c.lean, c.sway, c.headYaw, c.headTilt, c.headPitch, c.bounce / 10, c.armsOut / 2, c.armsForward, c.elbows / 2, c.handUp,
                              c.smile, c.mouth, c.brow, c.browLift, c.blush, c.eyeOpen - 1, c.lookX, c.lookY, c.squash - 1, c.twitch]
                if values.contains(where: { !$0.isFinite || abs($0) > 1.01 }) { bounded = false }
            }
        }
        expect(bounded, "every cue stays within what a body can do")

        // The moment you press Return.
        func answer(_ text: String) -> Listening.Response { Listening.response(to: Listening.read(text, name: "Pip")) }
        expect(answer("do a flip") == .move("flip"), "asked to flip, it flips")
        expect(answer("take a bow") == .move("bow"), "asked to take a bow, it bows")
        expect(answer("do a triple hop") == .move("hops"), "asked for a triple hop, it hops three times")
        expect(answer("hello!") == .gesture("wave", emote: nil), "hello gets a wave")
        expect(answer("thank you") == .gesture("bow", emote: "♥"), "thanks gets a bow")
        expect(answer("WE DID IT!!!") == .hop(emote: "♪"), "big news gets a jump")
        expect(answer("whoa no way!") == .hop(emote: "!"), "surprise gets a startled hop")
        expect(answer("hmm interesting") == .gesture("think", emote: "?"), "curiosity gets a thoughtful look")
        expect(answer("what do you think?") == .gesture("think", emote: "?"), "a question gets a thoughtful look")
        expect(answer("I had a rough day") == .gesture("nod", emote: nil), "bad news gets a quiet nod, never a dance")
        expect(answer("Summarise the attached report in three bullets") == .nothing, "plain work gets no performance")

        print("")
        print(failures.isEmpty ? "LISTENING CHECK OK: \(checks) checks" : "LISTENING CHECK FAILED: \(failures.count) of \(checks)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
