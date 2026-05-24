import Foundation

enum AppViewModelPreferences {
    static let suppressUSBPrivilegeNotice = "suppressUSBPrivilegeNotice"
    static let savedRoutes = "savedRoutes"
    static let savedLocations = "savedLocations"
}

struct MovementControlVector: Equatable, Sendable {
    var x: Double
    var y: Double

    static let zero = MovementControlVector(x: 0, y: 0)

    init(x: Double, y: Double) {
        let magnitude = sqrt(x * x + y * y)

        if magnitude > 1, magnitude > 0 {
            self.x = x / magnitude
            self.y = y / magnitude
        } else {
            self.x = x
            self.y = y
        }
    }

    var magnitude: Double {
        min(1, sqrt(x * x + y * y))
    }

    var isZero: Bool {
        magnitude < 0.001
    }

    var normalized: MovementControlVector {
        let magnitude = magnitude
        guard magnitude >= 0.001 else {
            return .zero
        }

        return MovementControlVector(x: x / magnitude, y: y / magnitude)
    }
}

struct USBSetupGuide: Equatable {
    let resolvedPythonPath: String?
    let installCommand: String?

    var pythonInstallCommand: String {
        if let installCommand, !installCommand.isEmpty {
            return installCommand
        }

        if let resolvedPythonPath {
            return Self.shellQuoted(resolvedPythonPath) + " -m pip install --user --upgrade pymobiledevice3"
        }

        return "python3 -m pip install --user --upgrade pymobiledevice3"
    }

    var pythonStatusText: String {
        if let resolvedPythonPath {
            return resolvedPythonPath
        }

        return String(localized: TeleportStrings.pythonUnavailableInShell)
    }

    private static func shellQuoted(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || $0 == "'" }) else {
            return value
        }

        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct PythonDependencyInstallGuide: Identifiable, Equatable {
    let resolvedPythonPath: String
    let installCommand: String
    let installedVersion: String?
    let minimumSupportedVersion: String?

    var id: String {
        [resolvedPythonPath, installCommand, installedVersion ?? "", minimumSupportedVersion ?? ""].joined(
            separator: "\n")
    }

    static func parse(from message: String) -> PythonDependencyInstallGuide? {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard
            lines.contains(where: { $0.localizedCaseInsensitiveContains("requires pymobiledevice3") })
                || lines.contains(where: { $0.localizedCaseInsensitiveContains("pymobiledevice3 is missing") })
                || lines.contains(where: { $0.localizedCaseInsensitiveContains("version is too old") })
        else {
            return nil
        }

        guard
            let resolvedPythonPath = lines.first(where: { $0.hasPrefix("Resolved Python: ") })?
                .replacingOccurrences(of: "Resolved Python: ", with: ""),
            let installCommand = lines.first(where: { $0.hasPrefix("Run: ") })?
                .replacingOccurrences(of: "Run: ", with: "")
        else {
            return nil
        }

        return PythonDependencyInstallGuide(
            resolvedPythonPath: resolvedPythonPath,
            installCommand: installCommand,
            installedVersion: lines.first(where: { $0.hasPrefix("Installed pymobiledevice3: ") })?
                .replacingOccurrences(of: "Installed pymobiledevice3: ", with: ""),
            minimumSupportedVersion: lines.first(where: { $0.hasPrefix("Minimum supported pymobiledevice3: ") })?
                .replacingOccurrences(of: "Minimum supported pymobiledevice3: ", with: "")
        )
    }
}
