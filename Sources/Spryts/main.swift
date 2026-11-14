import AppKit

// The program starts on the main thread; say so explicitly so the app delegate can be created here.
if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "focus" {
    // `Spryts focus …` runs Pip's focus tools from a shell and exits. No characters, no menu bar icon.
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let code = await FocusCLI.run(Array(CommandLine.arguments.dropFirst(2)))
            exit(code)
        }
    }
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
