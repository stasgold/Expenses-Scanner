import SwiftUI
import UIKit

/// A single-field alert: rename a trip or a person.
struct TextPrompt: Identifiable {
    let id = UUID()
    var title: String
    var placeholder: String
    var initialText: String = ""
    var confirmTitle: String = L10n.save
    var keyboard: UIKeyboardType = .default
    /// Optional hint shown under the title.
    var message: String? = nil
    /// Called with the trimmed text; blank input is ignored.
    var onConfirm: (String) -> Void
}

/// An "are you sure?" alert for resets and deletions.
struct Confirmation: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmTitle: String
    var destructive: Bool = false
    var onConfirm: () -> Void
}

extension View {
    func textPrompt(_ prompt: Binding<TextPrompt?>) -> some View {
        modifier(TextPromptModifier(prompt: prompt))
    }

    func confirmation(_ confirmation: Binding<Confirmation?>) -> some View {
        alert(
            confirmation.wrappedValue?.title ?? "",
            isPresented: confirmation.isPresent(),
            presenting: confirmation.wrappedValue
        ) { item in
            Button(L10n.cancel, role: .cancel) {}
            Button(item.confirmTitle, role: item.destructive ? ButtonRole.destructive : nil, action: item.onConfirm)
        } message: { item in
            Text(item.message)
        }
    }
}

private struct TextPromptModifier: ViewModifier {
    @Binding var prompt: TextPrompt?
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert(prompt?.title ?? "", isPresented: $prompt.isPresent(), presenting: prompt) { item in
                TextField(item.placeholder, text: $text)
                    .keyboardType(item.keyboard)
                    .submitLabel(.done)
                Button(L10n.cancel, role: .cancel) {}
                Button(item.confirmTitle) {
                    let value = text.trimmed
                    if !value.isEmpty { item.onConfirm(value) }
                }
            } message: { item in
                if let message = item.message { Text(message) }
            }
            .onChange(of: prompt?.id) {
                text = prompt?.initialText ?? ""
            }
    }
}

extension Binding {
    /// `true` while an optional item is set; writing `false` clears it. Drives `alert(isPresented:)`.
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(
            get: { wrappedValue != nil },
            set: { if !$0 { wrappedValue = nil } }
        )
    }
}
