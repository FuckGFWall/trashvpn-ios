import Foundation

enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, simplifiedChinese = "zh-Hans", english = "en", traditionalChinese = "zh-Hant", persian = "fa"
    static let supported: [Self] = [.simplifiedChinese, .english, .traditionalChinese, .persian]
    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .system: return "跟随系统"
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .traditionalChinese: return "繁體中文"
        case .persian: return "فارسی"
        }
    }
    func resolved(preferredLanguages: [String]) -> Self {
        guard self == .system else { return self }
        let code = preferredLanguages.first?.lowercased() ?? ""
        if code.hasPrefix("zh") {
            return code.contains("hant") || code.contains("tw") || code.contains("hk") || code.contains("mo") ? .traditionalChinese : .simplifiedChinese
        }
        if code.hasPrefix("fa") { return .persian }
        if code.hasPrefix("en") { return .english }
        return .english
    }
    var resolved: Self { resolved(preferredLanguages: Locale.preferredLanguages) }
    var locale: Locale { Locale(identifier: resolved.rawValue) }
    var isRightToLeft: Bool { resolved == .persian }
    // Shared with the provider so its user-visible errors follow the app's language.
    static var current: Self {
        (UserDefaults(suiteName: WARPConfiguration.group)?.string(forKey: "appLanguage").flatMap(Self.init(rawValue:)) ?? .system).resolved
    }
    func persistSelection() {
        UserDefaults(suiteName: WARPConfiguration.group)?.set(rawValue, forKey: "appLanguage")
    }
    var bundle: Bundle {
        guard let path = Bundle.main.path(forResource: resolved.rawValue, ofType: "lproj"), let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
}

/// Retains the translation key and interpolation values, including in persisted progress.
/// Rendering at the view boundary lets an in-flight scan change languages immediately.
struct LocalizedText: Equatable, Codable, Sendable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation, CustomStringConvertible {
    let key: String
    let arguments: [LocalizedText]
    init(_ key: String) { self.key = key; arguments = [] }
    private init(key: String, arguments: [LocalizedText]) { self.key = key; self.arguments = arguments }
    init(stringLiteral value: String) { self.init(value) }
    init(stringInterpolation: StringInterpolation) { key = stringInterpolation.key; arguments = stringInterpolation.arguments }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [LocalizedText] = []
        init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount) }
        mutating func appendLiteral(_ literal: String) { key += literal.replacingOccurrences(of: "%", with: "%%") }
        mutating func appendInterpolation(_ value: LocalizedText) { arguments.append(value); key += "%\(arguments.count)$@" }
        mutating func appendInterpolation<T>(_ value: T) { appendInterpolation(LocalizedText(String(describing: value))) }
    }
    var source: String { render(key, arguments: arguments.map(\.source), locale: Locale(identifier: "zh-Hans")) }
    var description: String { source }
    func localized(in language: AppLanguage = .current) -> String {
        let format = language.bundle.localizedString(forKey: key, value: key, table: "Localizable")
        let values = arguments.map { argument -> String in
            let value = argument.localized(in: language)
            return language.isRightToLeft ? "\u{2068}" + value + "\u{2069}" : value
        }
        return render(format, arguments: values, locale: language.locale)
    }
    private func render(_ format: String, arguments: [String], locale: Locale) -> String {
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: arguments)
    }
    private enum CodingKeys: CodingKey { case key, arguments }
    init(from decoder: Decoder) throws {
        // Progress written by older versions stored plain strings.
        if let value = try? decoder.singleValueContainer().decode(String.self) { self.init(value); return }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try container.decode(String.self, forKey: .key), arguments: try container.decode([LocalizedText].self, forKey: .arguments))
    }
    func encode(to encoder: Encoder) throws {
        if arguments.isEmpty { var container = encoder.singleValueContainer(); try container.encode(key) }
        else {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(key, forKey: .key); try container.encode(arguments, forKey: .arguments)
        }
    }
}
