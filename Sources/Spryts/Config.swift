import AppKit

/// How a character looks. Colours are hex strings.
struct Look: Codable {
    var body: String
    var accent: String
    var skin: String
    var height: CGFloat
    var headScale: CGFloat
    var features: [String]   // antenna, stalks, ears, longears, roundears, horns, cape, scarf, tail, foxtail, dragontail, stub, wings, spikes
    var trim: String?        // colour for the scarf, beak, wings and other details

    // Shape. All optional; leave out for Pip's proportions.
    var head: String?        // round, wide, tall, flat, box
    var eyes: String?        // two, one, three
    var eyeSize: CGFloat?
    var snout: String?       // none, nose, muzzle, beak
    var legs: CGFloat?       // length, 1 = normal
    var arms: CGFloat?
    var torso: CGFloat?      // width
    var limbs: CGFloat?      // thickness
    var feet: CGFloat?
    var belly: Bool?
    var build: String?       // the trunk: bean (the default), round, block
}

/// The handful of numbers that give each character its own way of moving.
struct MotionStyle: Codable {
    var speed: CGFloat      // points per second
    var stride: CGFloat     // leg swing, radians
    var bounce: CGFloat     // vertical bob, points
    var armSwing: CGFloat   // radians
    var lean: CGFloat       // forward lean, radians (negative = chest out)
    var tempo: CGFloat      // 1 = normal; higher = shorter pauses
    var fidget: CGFloat     // 0...1
    var jumpiness: CGFloat  // 0...1
    var sway: CGFloat       // side-to-side swagger, radians

    // A made Spryt's own way of moving. All optional; leave out for the standard behaviour. See Moves.swift.
    var walk: String?       // how an ordinary walk looks: natural, strut, march, waddle, bounce, glide, swing, shuffle
    var travel: String?     // how it likes to get around: mix, walk, skip, run, sneak
    var spring: CGFloat?    // jump height, 1 = normal
    var showOff: CGFloat?   // 0...1, how often it does one of its moves in a spare moment
    var moves: [String]?    // the moves it knows; leave out for the standard set
}

/// How a made Spryt sounds, and what it says to the others. Short lines for speech bubbles; never instructions.
struct SprytVoice: Codable, Equatable {
    var pitch: CGFloat?     // reading aloud: 1 = an ordinary voice
    var pace: CGFloat?
    var energy: CGFloat?    // how much the body joins in while talking
    var greeting: String?   // wave, nod, bow, pump, shrug
    var hellos: [String]?   // said to another Spryt; {name} becomes theirs
    var replies: [String]?  // said back

    static let greetings = ["wave", "nod", "bow", "pump", "shrug"]

    /// A file can be hand-edited, so everything is cut to size and anything unknown is dropped.
    var cleaned: SprytVoice {
        func lines(_ value: [String]?) -> [String]? {
            let kept = (value ?? []).prefix(6).compactMap { line -> String? in
                let flat = line.components(separatedBy: .controlCharacters).joined(separator: " ")
                    .components(separatedBy: .newlines).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                return flat.isEmpty ? nil : String(flat.prefix(70))
            }
            return kept.isEmpty ? nil : Array(kept)
        }
        func bounded(_ value: CGFloat?, _ range: ClosedRange<CGFloat>) -> CGFloat? {
            guard let value, value.isFinite else { return nil }
            return min(range.upperBound, max(range.lowerBound, value))
        }
        return SprytVoice(pitch: bounded(pitch, 0.7...1.5), pace: bounded(pace, 0.8...1.3), energy: bounded(energy, 0.4...1.2),
                          greeting: SprytVoice.greetings.contains(greeting ?? "") ? greeting : nil,
                          hellos: lines(hellos), replies: lines(replies))
    }
}

/// One file per character: who it is in text and who it is in motion.
struct CharacterSheet: Codable {
    var id: String
    var name: String
    var provider: String    // "claude" or "grok"
    var model: String
    var persona: String
    var look: Look
    var motion: MotionStyle
    var meshyModel: String?
    var modelYaw: CGFloat?
    var requiresModel: Bool?
    var harness: String?    // "claude-code" runs the character on Claude Code instead of a plain chat API
    var sleepAfter: CGFloat? // seconds without being hovered, clicked or spoken to before it falls asleep
    var order: Int?          // lower numbers come first; the first character answers the hotkey
    var role: String?        // "coder" gets coding instructions, project permissions and the workspace window
    var signature: String?   // a move only this creature has: smoke, stalks, ears, spark
    var custom: Bool?        // made in the Spryt maker, or opened from a .spryt file
    var quirks: [String]?    // habits switched off: noflips, nonaps
    var makerPersona: String? // the personality as its maker typed it, kept so it can be edited again
    var voice: SprytVoice?    // a made Spryt's speaking voice and neighbourly lines

    func has(_ quirk: String) -> Bool { (quirks ?? []).contains(quirk) }
}

enum Config {
    static let home: URL = {
        if let h = ProcessInfo.processInfo.environment["SPRYTS_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h)
        }
        // Launched as an app (from Finder, the Dock or at login): the build script leaves the folder's path here.
        let note = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Spryts/home")
        if let h = try? String(contentsOf: note, encoding: .utf8), !h.isEmpty,
           FileManager.default.fileExists(atPath: h) {
            return URL(fileURLWithPath: h)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }()

    static let env: [String: String] = {
        var out: [String: String] = [:]
        let url = home.appendingPathComponent(".env")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            for rawLine in text.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                if !value.isEmpty { out[key] = value }
            }
        }
        return out
    }()

    static func key(_ name: String) -> String? {
        if let v = env[name], !v.isEmpty { return v }
        if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty { return v }
        return nil
    }

    static func modelFolder(_ name: String) -> URL {
        home.appendingPathComponent("Characters").appendingPathComponent("models").appendingPathComponent(name)
    }

    static func loadSheets() -> [CharacterSheet] {
        var sheets: [CharacterSheet] = []
        let dir = home.appendingPathComponent("Characters")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let sheet = try JSONDecoder().decode(CharacterSheet.self, from: data)
                if sheet.requiresModel == true {
                    let idle = modelFolder(sheet.meshyModel ?? sheet.id).appendingPathComponent("idle.usdz")
                    if !FileManager.default.fileExists(atPath: idle.path) { continue }
                }
                sheets.append(sheet)
            } catch {
                NSLog("Spryts: could not read \(file.lastPathComponent): \(error)")
            }
        }
        if sheets.isEmpty { sheets = [fallback] }
        // Stable sort by the optional order field, so the lead character stays first.
        let ranked = sheets.enumerated().sorted(by: { a, b in
            let ra = a.element.order ?? 99
            let rb = b.element.order ?? 99
            return ra != rb ? ra < rb : a.offset < b.offset
        })
        return ranked.map { $0.element }
    }

    static let fallback = CharacterSheet(
        id: "pip", name: "Pip", provider: "claude", model: "claude-haiku-5-5",
        persona: "You are Pip, a small upbeat sprite who lives on the user's desktop. Keep replies short.",
        look: Look(body: "#F2913D", accent: "#FFF1DC", skin: "#FFD9A8", height: 112, headScale: 1.2, features: ["antenna"]),
        motion: MotionStyle(speed: 85, stride: 0.55, bounce: 5, armSwing: 0.7, lean: 0.08, tempo: 1.3, fidget: 0.7, jumpiness: 0.8, sway: 0.05),
        meshyModel: nil, modelYaw: nil, requiresModel: nil)
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
