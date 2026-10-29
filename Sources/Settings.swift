import Foundation

enum Style: Int, CaseIterable {
    case halo, aurora, lines, stars

    var title: String {
        switch self {
        case .halo: return "Halo"
        case .aurora: return "Aurora"
        case .lines: return "Contours"
        case .stars: return "Starfield"
        }
    }
}

enum Theme: Int, CaseIterable {
    case spectrum, ocean, ember, violet

    var title: String {
        switch self {
        case .spectrum: return "Spectrum (cycling)"
        case .ocean: return "Ocean"
        case .ember: return "Ember"
        case .violet: return "Violet"
        }
    }
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "style": Style.halo.rawValue,
            "theme": Theme.spectrum.rawValue,
            "brightness": 0.8,
            "sensitivity": 1.0,
            "fps": 60,
            "autoCycle": true,
            "paused": false,
        ])
    }

    var style: Style {
        get { Style(rawValue: d.integer(forKey: "style")) ?? .halo }
        set { d.set(newValue.rawValue, forKey: "style") }
    }
    var theme: Theme {
        get { Theme(rawValue: d.integer(forKey: "theme")) ?? .spectrum }
        set { d.set(newValue.rawValue, forKey: "theme") }
    }
    var brightness: Float {
        get { d.float(forKey: "brightness") }
        set { d.set(newValue, forKey: "brightness") }
    }
    var sensitivity: Float {
        get { d.float(forKey: "sensitivity") }
        set { d.set(newValue, forKey: "sensitivity") }
    }
    var fps: Int {
        get { d.integer(forKey: "fps") }
        set { d.set(newValue, forKey: "fps") }
    }
    /// Rotates styles every few minutes so no pattern sits in one place for long (OLED burn-in guard).
    var autoCycle: Bool {
        get { d.bool(forKey: "autoCycle") }
        set { d.set(newValue, forKey: "autoCycle") }
    }
    var paused: Bool {
        get { d.bool(forKey: "paused") }
        set { d.set(newValue, forKey: "paused") }
    }
}
