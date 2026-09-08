import SwiftUI

struct PresetControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: SettingsStore
    @State private var isNaming = false
    @State private var name = ""
    @State private var error: String?

    init(model: AppModel) { self.model = model; preferences = model.preferences }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Preset").font(.system(size: 11, weight: .medium))
                HelpTip(title: "Settings and presets", text: "Your controls are remembered across launches. A preset saves those controls, including pauses and the fullscreen overlay, so you can switch setups quickly. It does not save source text or replace a typing profile. Up to 30 personal presets can be kept.")
                Spacer()
                Button("Save…") { isNaming = true; error = nil }.buttonStyle(QuietButtonStyle())
            }
            Menu {
                ForEach(preferences.presets) { preset in
                    Button(preset.name) { model.settings = preset.settings }
                }
                if preferences.presets.contains(where: { !$0.builtIn }) {
                    Divider()
                    Menu("Delete saved preset") {
                        ForEach(preferences.presets.filter { !$0.builtIn }) { preset in
                            Button(preset.name, role: .destructive) { preferences.remove(preset.id) }
                        }
                    }
                }
            } label: {
                Text(preferences.presets.first(where: { $0.settings == model.settings })?.name ?? "Custom settings")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isNaming {
                TextField("Preset name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
                HStack {
                    Button("Save preset", action: save).buttonStyle(SecondaryButtonStyle())
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { isNaming = false }.buttonStyle(QuietButtonStyle())
                }
                if let error { Text(error).font(.caption).foregroundStyle(TyperTheme.danger) }
            }
        }.disabled(model.controller.state.isBusy)
    }

    private func save() {
        guard preferences.add(name: name, settings: model.settings) != nil else {
            error = "Choose a unique name. You can keep up to 30 personal presets."
            return
        }
        isNaming = false; name = ""; error = nil
        model.showToast("Preset saved.")
    }
}
