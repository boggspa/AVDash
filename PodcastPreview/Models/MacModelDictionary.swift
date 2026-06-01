//
//  MacModelDictionary.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 17/12/2025.
//

import Foundation

// MARK: - Public Types

enum MacFamily: String {
    case macBook
    case macBookAir
    case macBookPro
    case macMini
    case iMac
    case macStudio
    case macPro
    case mac
}

struct ModelInfo {
    let modelName: String   // e.g. "Mac Studio"
    let releaseYear: String // e.g. "2022" (year only)
    let family: MacFamily
}

// MARK: - Lookup

enum MacModelDictionary {

    /// Returns model info for identifiers like "Mac13,1" or "MacBookPro16,1".
    static func lookup(_ identifier: String) -> ModelInfo? {
        let key = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return nil }

        // Fast path: already built
        if let cached = cache[key] { return cached }

        // Slow path: build once
        buildCacheIfNeeded()
        return cache[key]
    }

    // MARK: - Private

    private static var didBuild = false
    private static var cache: [String: ModelInfo] = [:]

    private static func buildCacheIfNeeded() {
        guard !didBuild else { return }
        didBuild = true

        // Primary dataset (curated, sourced from Apple support page scraping)
        // https://github.com/kyle-seongwoo-jun/apple-device-identifiers (mac-device-identifiers.json)
        // Note: values are a string OR an array of strings. We pick the first for display.
        let json = macDeviceIdentifiersJSON

        if let data = json.data(using: .utf8) {
            do {
                let obj = try JSONSerialization.jsonObject(with: data, options: [])
                if let dict = obj as? [String: Any] {
                    for (identifier, value) in dict {
                        let raw: String?
                        if let s = value as? String {
                            raw = s
                        } else if let arr = value as? [Any], let first = arr.first as? String {
                            raw = first
                        } else {
                            raw = nil
                        }

                        guard let rawName = raw else { continue }
                        if let info = parseModelInfo(from: rawName) {
                            cache[identifier] = info
                        }
                    }
                }
            } catch {
                // If parsing fails, we still keep manual fallbacks below.
            }
        }

        // Manual additions / backfills for some older 2007-era models that may not appear in the scraped dataset.
        // (These are safe to be imperfect; unknown entries will just fall back.)
        let manual: [String: String] = [
            "iMac7,1": "iMac (20-inch, Mid 2007)",
            "MacBook2,1": "MacBook (13-inch, Late 2006)",
            "MacBook3,1": "MacBook (13-inch, Mid 2007)",
            "MacBookPro3,1": "MacBook Pro (15-inch/17-inch, Mid 2007)",
            "Macmini2,1": "Mac mini (Mid 2007)",
            "MacPro2,1": "Mac Pro (Mid 2007)"
        ]

        for (id, raw) in manual {
            if cache[id] == nil, let info = parseModelInfo(from: raw) {
                cache[id] = info
            }
        }
    }

    private static func parseModelInfo(from raw: String) -> ModelInfo? {
        // Examples:
        // "Mac Studio (2022)"
        // "MacBook Pro (16-inch, Nov 2023)"
        // "MacBook Air (11-inch, Late 2010)"

        let year = extractYear(from: raw) ?? "Unknown"
        let baseName = extractBaseModelName(from: raw)

        let family = classifyFamily(fromBaseName: baseName)

        return ModelInfo(modelName: baseName, releaseYear: year, family: family)
    }

    private static func extractBaseModelName(from raw: String) -> String {
        // Base name = text before the first '(' if present.
        if let idx = raw.firstIndex(of: "(") {
            let prefix = raw[..<idx]
            let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        // Some strings may not have parentheses.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Mac" : trimmed
    }

    private static func extractYear(from raw: String) -> String? {
        // Find a 4-digit year (2007–2025 etc).
        // Keep it very lightweight: scan for the first 4-digit run starting with 19/20.
        let chars = Array(raw)
        guard chars.count >= 4 else { return nil }

        for i in 0..<(chars.count - 3) {
            let a = chars[i]
            if a != "1" && a != "2" { continue }

            let s = String(chars[i...min(i + 3, chars.count - 1)])
            if s.count == 4, let _ = Int(s) {
                // Basic sanity: only accept plausible modern Mac years
                if s >= "2000" && s <= "2030" {
                    return s
                }
            }
        }

        return nil
    }

    private static func classifyFamily(fromBaseName base: String) -> MacFamily {
        // Prefer explicit families first
        if base.hasPrefix("MacBook Pro") { return .macBookPro }
        if base.hasPrefix("MacBook Air") { return .macBookAir }
        if base.hasPrefix("MacBook") { return .macBook }
        if base.hasPrefix("Mac mini") { return .macMini }
        if base.hasPrefix("Mac Studio") { return .macStudio }
        if base.hasPrefix("Mac Pro") { return .macPro }
        if base.hasPrefix("iMac") { return .iMac }

        return .mac
    }

    // This is a compressed copy of the upstream JSON content. Keep it as a single literal for build simplicity.
    // Source: https://github.com/kyle-seongwoo-jun/apple-device-identifiers/blob/main/mac-device-identifiers.json
    private static let macDeviceIdentifiersJSON: String =
    #"{ "iMac9,1": [ "iMac (20-inch, Early 2009)", "iMac (24-inch, Early 2009)" ], "iMac10,1": [ "iMac (21.5-inch, Late 2009)", "iMac (27-inch, Late 2009)" ], "iMac11,2": "iMac (21.5-inch, Mid 2010)", "iMac11,3": "iMac (27-inch, Mid 2010)", "iMac12,1": "iMac (21.5-inch, Mid 2011)", "iMac12,2": "iMac (27-inch, Mid 2011)", "iMac13,1": "iMac (21.5-inch, Late 2012)", "iMac13,2": "iMac (27-inch, Late 2012)", "iMac14,1": "iMac (21.5-inch, Late 2013)", "iMac14,2": "iMac (27-inch, Late 2013)", "iMac14,4": "iMac (21.5-inch, Mid 2014)", "iMac15,1": [ "iMac (Retina 5K, 27-inch, Late 2014)", "iMac (Retina 5K, 27-inch, Mid 2015)" ], "iMac16,1": "iMac (21.5-inch, Late 2015)", "iMac16,2": "iMac (Retina 4K, 21.5-inch, Late 2015)", "iMac17,1": "iMac (Retina 5K, 27-inch, Late 2015)", "iMac18,1": "iMac (21.5-inch, 2017)", "iMac18,2": "iMac (Retina 4K, 21.5-inch, 2017)", "iMac18,3": "iMac (Retina 5K, 27-inch, 2017)", "iMac19,1": "iMac (Retina 5K, 27-inch, 2019)", "iMac19,2": "iMac (Retina 4K, 21.5-inch, 2019)", "iMac20,1": "iMac (Retina 5K, 27-inch, 2020)", "iMac20,2": "iMac (Retina 5K, 27-inch, 2020)", "iMac21,1": "iMac (24-inch, M1, 2021)", "iMac21,2": "iMac (24-inch, M1, 2021)", "iMacPro1,1": "iMac Pro (2017)", "Mac13,1": "Mac Studio (2022)", "Mac13,2": "Mac Studio (2022)", "Mac14,2": "MacBook Air (M2, 2022)", "Mac14,3": "Mac mini (2023)", "Mac14,5": "MacBook Pro (14-inch, 2023)", "Mac14,6": "MacBook Pro (16-inch, 2023)", "Mac14,7": "MacBook Pro (13-inch, M2, 2022)", "Mac14,8": [ "Mac Pro (2023)", "Mac Pro (Rack, 2023)" ], "Mac14,9": "MacBook Pro (14-inch, 2023)", "Mac14,10": "MacBook Pro (16-inch, 2023)", "Mac14,12": "Mac mini (2023)", "Mac14,13": "Mac Studio (2023)", "Mac14,14": "Mac Studio (2023)", "Mac14,15": "MacBook Air (15-inch, M2, 2023)", "Mac15,3": "MacBook Pro (14-inch, Nov 2023)", "Mac15,4": "iMac (24-inch, 2023, Two ports)", "Mac15,5": "iMac (24-inch, 2023, Four ports)", "Mac15,6": "MacBook Pro (14-inch, Nov 2023)", "Mac15,7": "MacBook Pro (16-inch, Nov 2023)", "Mac15,8": "MacBook Pro (14-inch, Nov 2023)", "Mac15,9": "MacBook Pro (16-inch, Nov 2023)", "Mac15,10": "MacBook Pro (14-inch, Nov 2023)", "Mac15,11": "MacBook Pro (16-inch, Nov 2023)", "Mac15,12": "MacBook Air (13-inch, M3, 2024)", "Mac15,13": "MacBook Air (15-inch, M3, 2024)", "Mac15,14": "Mac Studio (2025)", "Mac16,1": "MacBook Pro (14-inch, 2024)", "Mac16,2": "iMac (24-inch, 2024, Two ports)", "Mac16,3": "iMac (24-inch, 2024, Four ports)", "Mac16,5": "MacBook Pro (16-inch, 2024)", "Mac16,6": "MacBook Pro (14-inch, 2024)", "Mac16,7": "MacBook Pro (16-inch, 2024)", "Mac16,8": "MacBook Pro (14-inch, 2024)", "Mac16,9": "Mac Studio (2025)", "Mac16,10": "Mac mini (2024)", "Mac16,11": "Mac mini (2024)", "Mac16,12": "MacBook Air (13-inch, M4, 2025)", "Mac16,13": "MacBook Air (15-inch, M4, 2025)", "Mac17,2": "MacBook Pro (14-inch, M5)", "MacBook5,2": [ "MacBook (13-inch, Early 2009)", "MacBook (13-inch, Mid 2009)" ], "MacBook6,1": "MacBook (13-inch, Late 2009)", "MacBook7,1": "MacBook (13-inch, Mid 2010)", "MacBook8,1": "MacBook (Retina, 12-inch, Early 2015)", "MacBook9,1": "MacBook (Retina, 12-inch, Early 2016)", "MacBook10,1": "MacBook (Retina, 12-inch, 2017)", "MacBookAir2,1": "MacBook Air (Mid 2009)", "MacBookAir3,1": "MacBook Air (11-inch, Late 2010)", "MacBookAir3,2": "MacBook Air (13-inch, Late 2010)", "MacBookAir4,1": "MacBook Air (11-inch, Mid 2011)", "MacBookAir4,2": "MacBook Air (13-inch, Mid 2011)", "MacBookAir5,1": "MacBook Air (11-inch, Mid 2012)", "MacBookAir5,2": "MacBook Air (13-inch, Mid 2012)", "MacBookAir6,1": [ "MacBook Air (11-inch, Early 2014)", "MacBook Air (11-inch, Mid 2013)" ], "MacBookAir6,2": [ "MacBook Air (13-inch, Early 2014)", "MacBook Air (13-inch, Mid 2013)" ], "MacBookAir7,1": "MacBook Air (11-inch, Early 2015)", "MacBookAir7,2": [ "MacBook Air (13-inch, 2017)", "MacBook Air (13-inch, Early 2015)" ], "MacBookAir8,1": "MacBook Air (Retina, 13-inch, 2018)", "MacBookAir8,2": "MacBook Air (Retina, 13-inch, 2019)", "MacBookAir9,1": "MacBook Air (Retina, 13-inch, 2020)", "MacBookAir10,1": "MacBook Air (M1, 2020)", "MacBookPro4,1": [ "MacBook Pro (15-inch, Early 2008)", "MacBook Pro (17-inch, Early 2008)" ], "MacBookPro5,1": "MacBook Pro (15-inch, Late 2008)", "MacBookPro5,2": [ "MacBook Pro (17-inch, Early 2009)", "MacBook Pro (17-inch, Mid 2009)" ], "MacBookPro5,3": [ "MacBook Pro (15-inch, 2.53GHz, Mid 2009)", "MacBook Pro (15-inch, Mid 2009)" ], "MacBookPro5,5": "MacBook Pro (13-inch, Mid 2009)", "MacBookPro6,1": "MacBook Pro (17-inch, Mid 2010)", "MacBookPro6,2": "MacBook Pro (15-inch, Mid 2010)", "MacBookPro7,1": "MacBook Pro (13-inch, Mid 2010)", "MacBookPro8,1": [ "MacBook Pro (13-inch, Early 2011)", "MacBook Pro (13-inch, Late 2011)" ], "MacBookPro8,2": [ "MacBook Pro (15-inch, Early 2011)", "MacBook Pro (15-inch, Late 2011)" ], "MacBookPro8,3": [ "MacBook Pro (17-inch, Early 2011)", "MacBook Pro (17-inch, Late 2011)" ], "MacBookPro9,1": "MacBook Pro (15-inch, Mid 2012)", "MacBookPro9,2": "MacBook Pro (13-inch, Mid 2012)", "MacBookPro10,1": [ "MacBook Pro (Retina, 15-inch, Early 2013)", "MacBook Pro (Retina, 15-inch, Mid 2012)" ], "MacBookPro10,2": [ "MacBook Pro (Retina, 13-inch, Early 2013)", "MacBook Pro (Retina, 13-inch, Late 2012)" ], "MacBookPro11,1": [ "MacBook Pro (Retina, 13-inch, Late 2013)", "MacBook Pro (Retina, 13-inch, Mid 2014)" ], "MacBookPro11,2": [ "MacBook Pro (Retina, 15-inch, Late 2013)", "MacBook Pro (Retina, 15-inch, Mid 2014)" ], "MacBookPro11,3": [ "MacBook Pro (Retina, 15-inch, Late 2013)", "MacBook Pro (Retina, 15-inch, Mid 2014)" ], "MacBookPro11,4": "MacBook Pro (Retina, 15-inch, Mid 2015)", "MacBookPro11,5": "MacBook Pro (Retina, 15-inch, Mid 2015)", "MacBookPro12,1": "MacBook Pro (Retina, 13-inch, Early 2015)", "MacBookPro13,1": "MacBook Pro (13-inch, 2016, Two Thunderbolt 3 ports)", "MacBookPro13,2": "MacBook Pro (13-inch, 2016, Four Thunderbolt 3 ports)", "MacBookPro13,3": "MacBook Pro (15-inch, 2016)", "MacBookPro14,1": "MacBook Pro (13-inch, 2017, Two Thunderbolt 3 ports)", "MacBookPro14,2": "MacBook Pro (13-inch, 2017, Four Thunderbolt 3 ports)", "MacBookPro14,3": "MacBook Pro (15-inch, 2017)", "MacBookPro15,1": [ "MacBook Pro (15-inch, 2018)", "MacBook Pro (15-inch, 2019)" ], "MacBookPro15,2": [ "MacBook Pro (13-inch, 2018, Four Thunderbolt 3 ports)", "MacBook Pro (13-inch, 2019, Four Thunderbolt 3 ports)" ], "MacBookPro15,3": "MacBook Pro (15-inch, 2019)", "MacBookPro15,4": "MacBook Pro (13-inch, 2019, Two Thunderbolt 3 ports)", "MacBookPro16,1": "MacBook Pro (16-inch, 2019)", "MacBookPro16,2": "MacBook Pro (13-inch, 2020, Four Thunderbolt 3 ports)", "MacBookPro16,3": "MacBook Pro (13-inch, 2020, Two Thunderbolt 3 ports)", "MacBookPro16,4": "MacBook Pro (16-inch, 2019)", "MacBookPro17,1": "MacBook Pro (13-inch, M1, 2020)", "MacBookPro18,1": "MacBook Pro (16-inch, 2021)", "MacBookPro18,2": "MacBook Pro (16-inch, 2021)", "MacBookPro18,3": "MacBook Pro (14-inch, 2021)", "MacBookPro18,4": "MacBook Pro (14-inch, 2021)", "Macmini3,1": [ "Mac mini (Early 2009)", "Mac mini (Late 2009)" ], "Macmini4,1": "Mac mini (Mid 2010)", "Macmini5,1": "Mac mini (Mid 2011)", "Macmini5,2": "Mac mini (Mid 2011)", "Macmini6,1": "Mac mini (Late 2012)", "Macmini6,2": "Mac mini (Late 2012)", "Macmini7,1": "Mac mini (Late 2014)", "Macmini8,1": "Mac mini (2018)", "Macmini9,1": "Mac mini (M1, 2020)", "MacPro4,1": "Mac Pro (Early 2009)", "MacPro5,1": [ "Mac Pro (Mid 2010)", "Mac Pro (Mid 2012)", "Mac Pro Server (Mid 2010)", "Mac Pro Server (Mid 2012)" ], "MacPro6,1": "Mac Pro (Late 2013)", "MacPro7,1": [ "Mac Pro (2019)", "Mac Pro (Rack, 2019)" ] }"#
}

