#if os(macOS)
import Combine
import Foundation
import FritCore

enum UpdateResources { static let bundle = Bundle.module }

func updateText(_ key: String.LocalizationValue, _ arguments: CVarArg...) -> String {
    let localized: String
    if let bundle = FritLocalization.overriddenBundle(in: .module) {
        localized = String(localized: key, bundle: bundle)
    } else {
        localized = String(localized: key, bundle: .module)
    }
    return arguments.isEmpty ? localized : String(format: localized, locale: FritLocalization.locale, arguments: arguments)
}

/// 共享语言变化会刷新所有视图；通知可以从任意线程发出。
@MainActor
final class UpdateLanguage: ObservableObject {
    static let shared = UpdateLanguage()
    @Published private(set) var revision = 0
    private var subscription: AnyCancellable?
    private init() {
        subscription = NotificationCenter.default.publisher(for: FritLocalization.languageDidChange).sink { [weak self] _ in
            Task { @MainActor in self?.revision += 1 }
        }
    }
}
#endif
