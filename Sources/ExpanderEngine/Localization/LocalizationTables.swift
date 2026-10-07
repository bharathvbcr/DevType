import Foundation

/// Loads the UI string tables from `Localization/Resources/<lang>.lproj/*.strings`.
///
/// The tables are read explicitly per `AppLanguage` instead of through
/// `Bundle.localizedString(forKey:value:table:)`: Foundation resolves a bundle's localization once,
/// from the system language list, while DevType lets the user pick a UI language that differs from
/// the system one and switch it at runtime.
///
/// Every `.strings` file in a language's `.lproj` is one table, and a language's tables are merged
/// into one key space. Adding a table therefore needs no code change; a key defined in two tables
/// is a data error reported in `diagnostics` (and asserted on by the parity tests).
enum LocalizationTables {
    /// Name of the SwiftPM resource bundle that carries `ExpanderEngine`'s resources.
    static let resourceBundleName = "DevType_ExpanderEngine"

    struct Loaded {
        let tables: [AppLanguage: [String: String]]
        /// Table names (file basenames) found for each language.
        let tableNames: [AppLanguage: [String]]
        /// Every problem met while loading: missing language directory, unreadable or malformed
        /// file, key defined twice. Empty when the resources are sound.
        let diagnostics: [String]
    }

    /// Loaded once per process. The tables are immutable resources, so every reader shares them.
    static let shared: Loaded = {
        let loaded = load(from: resourceBundle())
        for problem in loaded.diagnostics {
            DevTypeLog.app.error("Localization resources: \(problem, privacy: .public)")
        }
        assert(loaded.diagnostics.isEmpty, "Localization resources: \(loaded.diagnostics)")
        return loaded
    }()

    /// The bundle holding the `.lproj` directories.
    ///
    /// A packaged app carries it in `Contents/Resources` (copied there by `Scripts/package-app.sh`).
    /// That location is checked explicitly so finding it does not depend on which candidate list
    /// the toolchain's generated `Bundle.module` accessor happens to use. Anything else — `swift
    /// test`, `swift run` — is the build-tree layout `Bundle.module` knows; when the bundle is
    /// missing there too, `Bundle.module` stops the process naming the bundle, which is the
    /// correct outcome for an app whose every label would otherwise be a raw key.
    static func resourceBundle() -> Bundle {
        let file = resourceBundleName + ".bundle"
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        for candidate in candidates {
            if let url = candidate?.appendingPathComponent(file), let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return Bundle.module
    }

    static func load(from bundle: Bundle) -> Loaded {
        var tables: [AppLanguage: [String: String]] = [:]
        var names: [AppLanguage: [String]] = [:]
        var diagnostics: [String] = []
        for language in AppLanguage.concreteCases {
            let directory = bundle.resourceURL?.appendingPathComponent("\(language.rawValue).lproj")
            let files = directory.flatMap {
                try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
            }?.filter { $0.pathExtension == "strings" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            if files.isEmpty {
                diagnostics.append("\(language.rawValue).lproj has no .strings tables")
            }
            var merged: [String: String] = [:]
            var origin: [String: String] = [:]
            for file in files {
                let tableName = file.deletingPathExtension().lastPathComponent
                switch parse(file) {
                case .success(let entries):
                    for (key, value) in entries {
                        if let first = origin[key] {
                            diagnostics.append(
                                "\(language.rawValue): \"\(key)\" is defined in both \(first) and \(tableName)"
                            )
                            continue
                        }
                        origin[key] = tableName
                        merged[key] = value
                    }
                case .failure(let reason):
                    diagnostics.append("\(language.rawValue)/\(file.lastPathComponent): \(reason)")
                }
            }
            tables[language] = merged
            names[language] = files.map { $0.deletingPathExtension().lastPathComponent }
        }
        return Loaded(tables: tables, tableNames: names, diagnostics: diagnostics)
    }

    private static func parse(_ file: URL) -> Result<[String: String], LoadFailure> {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            return .failure(LoadFailure("unreadable: \(error.localizedDescription)"))
        }
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            return .failure(LoadFailure("malformed: \(error.localizedDescription)"))
        }
        guard let entries = plist as? [String: String] else {
            return .failure(LoadFailure("not a flat key = \"value\" table"))
        }
        return .success(entries)
    }

    struct LoadFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
