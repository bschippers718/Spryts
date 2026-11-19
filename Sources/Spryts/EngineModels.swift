import AppKit
import SwiftUI

/// Every workspace chooses its own engine. The running task keeps a stable model.
struct EngineModelMenu: View {
    @ObservedObject var session: ChatSession

    var body: some View {
        Menu {
            if session.sheet.harness != nil {
                Menu("Engine: " + session.engineLabel) {
                    ForEach(session.engineChoices, id: \.id) { choice in
                        Button { session.selectEngine(choice.id) } label: {
                            if session.engine == choice.id { Label(choice.label, systemImage: "checkmark") }
                            else { Text(choice.label) }
                        }
                    }
                }
            }
            Menu("Model: " + session.modelLabel) {
                ForEach(session.modelChoices, id: \.id) { choice in
                    Button { session.model = choice.id } label: {
                        if session.model == choice.id { Label(choice.label, systemImage: "checkmark") }
                        else { Text(choice.label) }
                    }
                }
                Divider()
                Button("Use a model ID…", action: chooseModel)
            }
            if session.engine == "codex" {
                Button(session.loadingModels ? "Checking models…" : "Refresh available models") { session.refreshModels() }
                    .disabled(session.loadingModels)
                if !session.modelProblem.isEmpty {
                    Button("Model list unavailable…") {
                        let alert = NSAlert()
                        alert.messageText = "Couldn't load Codex models"
                        alert.informativeText = session.modelProblem
                        alert.runModal()
                    }
                }
            }
            if session.sheet.harness != nil {
                Divider()
                Button("Connect to " + session.engineLabel + "…") { Connector.of(session.engine).connect() }
            }
        } label: {
            Label(session.engineLabel + " · " + session.modelLabel, systemImage: "cpu")
                .lineLimit(1)
        }
        .disabled(session.busy)
        .help("Choose the engine and model for " + session.sheet.name)
        .onAppear {
            if session.engine == "codex" && session.discoveredModels.isEmpty { session.refreshModels() }
        }
    }

    private func chooseModel() {
        guard !session.busy else { return }
        let alert = NSAlert()
        alert.messageText = "Choose a model for " + session.sheet.name
        alert.informativeText = "Enter a model supported by " + session.engineLabel + " and your account. Leave it blank to use the agent's default."
        alert.addButton(withTitle: "Use Model")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: session.model)
        field.placeholderString = "Model ID"
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 26)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !session.busy else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if session.sheet.harness == nil && value.isEmpty { return }
        session.model = value
    }
}
