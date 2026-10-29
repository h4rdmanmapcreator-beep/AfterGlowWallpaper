import Foundation

enum Style: Int, CaseIterable {
    case halo, lines, stars, bars, scope, blackHole, gradients, grid

    var title: String {
        switch self {
        case .halo: return "Halo"
        case .lines: return "Contours"
        case .stars: return "Starfield"
        case .bars: return "Equalizer"
        case .scope: return "Oscilloscope"
        case .blackHole: return "Black Hole"
        case .gradients: return "Gradients"
        case .grid: return "Neon Grid"
        }
    }
}

enum BlackHoleSize: Int, CaseIterable {
    case small, medium, huge

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .huge: return "Huge (off to the side)"
        }
    }
}

enum Theme: Int, CaseIterable {
    // Raw values are what the shader and saved settings use; declaration order is the menu order.
    case spectrum = 0, sunset = 4, cyberpunk = 5, nature = 7, ocean = 1, ice = 9, ember = 2, violet = 3

    var title: String {
        switch self {
        case .spectrum: return "Spectrum (cycling)"
        case .sunset: return "Sunset"
        case .cyberpunk: return "Cyberpunk"
        case .nature: return "Nature"
        case .ocean: return "Ocean"
        case .ice: return "Ice"
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
            "blackHoleStars": true,
            "blackHoleSize": BlackHoleSize.medium.rawValue,
            "lowFPSWhenSilent": false,
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
    /// Small stars orbiting the black hole, which make the lensing easy to see.
    var blackHoleStars: Bool {
        get { d.bool(forKey: "blackHoleStars") }
        set { d.set(newValue, forKey: "blackHoleStars") }
    }
    var blackHoleSize: BlackHoleSize {
        get { BlackHoleSize(rawValue: d.integer(forKey: "blackHoleSize")) ?? .medium }
        set { d.set(newValue.rawValue, forKey: "blackHoleSize") }
    }
    /// Drop to 30 fps in ambient mode to save power.
    var lowFPSWhenSilent: Bool {
        get { d.bool(forKey: "lowFPSWhenSilent") }
        set { d.set(newValue, forKey: "lowFPSWhenSilent") }
    }
}
