import Foundation

/// Whether the user has walked the welcome pages to the end.
///
/// It is not a setting: there is no control for it in the Settings window, and it is not a choice the
/// user makes. It is one fact about this Mac, which is why it lives here beside `QuietLaunch` rather
/// than on `Settings`, in the app's own preference domain so the uninstall takes it with everything
/// else.
///
/// **Only the last page's button writes it.** A window closed before that leaves it false, so the wizard
/// comes back at the next launch: a user who shut it to get on with something has not been shown the
/// permission it asks for.
public enum OnboardingState {
    private static let key = "onboardingCompleted"

    public static var completed: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
