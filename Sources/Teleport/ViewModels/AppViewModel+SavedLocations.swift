import AppKit
import Foundation

extension AppViewModel {
    func saveCurrentLocation() {
        guard let coordinate = currentCoordinate else {
            statusMessage = .localized(TeleportStrings.enterValidCoordinates)
            return
        }

        guard
            let locationName = promptForSavedItemName(
                title: TeleportStrings.saveLocationPromptTitle,
                message: TeleportStrings.saveLocationPromptMessage,
                defaultName: String(localized: TeleportStrings.newLocationName),
                actionTitle: TeleportStrings.saveLocation
            )
        else {
            return
        }

        savedLocations.insert(
            SavedLocation(name: locationName, coordinate: coordinate),
            at: 0
        )
        persistSavedLocations()
        statusMessage = .localized(TeleportStrings.savedLocationInApp(locationName))
    }

    func loadSavedLocation(_ location: SavedLocation) {
        latitudeText = String(format: "%.6f", location.coordinate.latitude)
        longitudeText = String(format: "%.6f", location.coordinate.longitude)
        statusMessage = .localized(TeleportStrings.loadedSavedLocation(location.name))
    }

    func renameSavedLocation(_ location: SavedLocation) {
        guard
            let locationName = promptForSavedItemName(
                title: TeleportStrings.renameLocationPromptTitle,
                message: TeleportStrings.renameLocationPromptMessage,
                defaultName: location.name,
                actionTitle: TeleportStrings.savedLocationRename
            )
        else {
            return
        }

        guard let existingIndex = savedLocations.firstIndex(where: { $0.id == location.id }) else {
            return
        }

        savedLocations[existingIndex].name = locationName
        persistSavedLocations()
        statusMessage = .localized(TeleportStrings.renamedSavedLocation(locationName))
    }

    func deleteSavedLocation(_ location: SavedLocation) {
        savedLocations.removeAll { $0.id == location.id }
        persistSavedLocations()
        statusMessage = .localized(TeleportStrings.deletedSavedLocation(location.name))
    }

    func copySavedLocationCoordinates(_ location: SavedLocation) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(location.coordinate.formatted, forType: .string)
        statusMessage = .localized(TeleportStrings.copiedSavedLocationCoordinates(location.name))
    }
}
