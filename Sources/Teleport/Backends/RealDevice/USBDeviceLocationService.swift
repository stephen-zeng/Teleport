import Foundation
import OSLog

actor USBDeviceLocationService: LocationSimulationService {
    let supportedKinds: [DeviceKind] = [.physicalUSB, .physicalNetwork]

    private let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")

    private var connectedDevice: Device?
    private var activeCoordinate: LocationCoordinate?
    private let simulationRunner = USBDeviceSimulationRunner()

    func discoverDevices() async throws -> [Device] {
        TeleportLog.devices.info("Discovering physical devices from CoreDevice")
        let coreDevices = try loadCoreDeviceDevices()

        let discoveredDevices: [Device] =
            coreDevices
            .compactMap(makeDiscoveredDevice)
            .sorted { $0.name < $1.name }

        TeleportLog.devices.info("Discovered \(discoveredDevices.count) physical device(s)")
        return discoveredDevices
    }

    func resolvedPythonExecutablePathForDisplay() -> String? {
        simulationRunner.resolvedPythonExecutablePathForDisplay()
    }

    func resolvedPythonInstallCommandForDisplay() -> String? {
        simulationRunner.resolvedPythonInstallCommandForDisplay()
    }

    func connect(to device: Device) async throws {
        guard device.isAvailable else {
            TeleportLog.devices.warning(
                "Attempted to connect to unavailable physical device \(device.logLabel, privacy: .public)"
            )
            throw ServiceError.unavailable(String(localized: TeleportStrings.selectedPhysicalDeviceUnavailable))
        }

        if connectedDevice?.id != device.id {
            if connectedDevice != nil {
                TeleportLog.devices.debug("Switching active physical device to \(device.logLabel, privacy: .public)")
            }
            await simulationRunner.disconnect()
            activeCoordinate = nil
        }

        connectedDevice = device
        TeleportLog.devices.info("Physical device connected: \(device.logLabel, privacy: .public)")
    }

    func disconnect() async {
        if let connectedDevice {
            TeleportLog.devices.info("Disconnecting physical device \(connectedDevice.logLabel, privacy: .public)")
        }
        await simulationRunner.disconnect()
        connectedDevice = nil
        activeCoordinate = nil
    }

    func hasActiveSimulationSession() async -> Bool {
        simulationRunner.hasActiveSimulationSession()
    }

    func setLocation(_ coordinate: LocationCoordinate) async throws {
        guard let connectedDevice else {
            throw ServiceError.invalidSelection
        }

        try await simulationRunner.setLocation(coordinate, on: connectedDevice)
        activeCoordinate = coordinate
    }

    func clearLocation() async throws {
        guard let connectedDevice else {
            throw ServiceError.invalidSelection
        }

        try await simulationRunner.clearLocation(on: connectedDevice)
        activeCoordinate = nil
    }

    private func loadCoreDeviceDevices() throws -> [CoreDeviceRecord] {
        let tempDirectory = FileManager.default.temporaryDirectory
        let outputURL = tempDirectory.appendingPathComponent("teleport-devicectl.json")

        TeleportLog.devices.debug("Loading CoreDevice metadata for physical-device discovery")
        _ = try CommandRunner.run(
            xcrunURL,
            arguments: ["devicectl", "list", "devices", "--json-output", outputURL.path]
        )

        let data = try Data(contentsOf: outputURL)
        let response = try JSONDecoder().decode(CoreDeviceListResponse.self, from: data)
        return response.result?.devices ?? []
    }

    private func makeDiscoveredDevice(from device: CoreDeviceRecord) -> Device? {
        guard let hardwareProperties = device.hardwareProperties,
            hardwareProperties.platform == "iOS",
            hardwareProperties.reality == "physical"
        else {
            return nil
        }

        guard let udid = hardwareProperties.udid?.trimmingCharacters(in: .whitespacesAndNewlines),
            !udid.isEmpty
        else {
            TeleportLog.devices.warning(
                "Skipping physical iOS CoreDevice record without a UDID: \(device.identifier ?? "<unknown>", privacy: .public)"
            )
            return nil
        }

        let kind = physicalDeviceKind(for: device)
        let isAvailable = resolvedAvailability(for: device)
        let details =
            isAvailable
            ? availableDetails(for: device, kind: kind)
            : unavailableDetails(for: kind)

        return Device(
            id: udid,
            name: resolvedDeviceName(for: device, fallbackID: udid),
            kind: kind,
            osVersion: formattedOSVersion(for: device),
            isAvailable: isAvailable,
            details: details
        )
    }

    private func resolvedAvailability(for device: CoreDeviceRecord) -> Bool {
        let pairingState = device.connectionProperties?.pairingState
        let developerModeStatus = device.deviceProperties?.developerModeStatus
        let isAvailable =
            pairingState == "paired"
            && developerModeStatus == "enabled"

        TeleportLog.devices.debug(
            "Resolved physical-device availability for \(self.resolvedDeviceName(for: device, fallbackID: "<unknown>"), privacy: .public); transport=\(device.connectionProperties?.transportType ?? "<nil>", privacy: .public), tunnelState=\(device.connectionProperties?.tunnelState ?? "<nil>", privacy: .public), pairing=\(pairingState ?? "<nil>", privacy: .public), developer mode=\(developerModeStatus ?? "<nil>", privacy: .public), ddiServices=\(device.deviceProperties?.ddiServicesAvailable ?? false, privacy: .public), available=\(isAvailable, privacy: .public)"
        )

        return isAvailable
    }

    private func physicalDeviceKind(for device: CoreDeviceRecord) -> DeviceKind {
        switch device.connectionProperties?.transportType?.lowercased() {
        case "localnetwork":
            return .physicalNetwork
        default:
            return .physicalUSB
        }
    }

    private func transportLabel(for kind: DeviceKind) -> String {
        switch kind {
        case .simulator:
            return "Simulator"
        case .physicalUSB:
            return "USB"
        case .physicalNetwork:
            return "Wi-Fi"
        }
    }

    private func unavailableDetails(for kind: DeviceKind) -> String {
        switch kind {
        case .simulator:
            return ""
        case .physicalUSB:
            return String(localized: TeleportStrings.usbDeviceUnavailableDetails)
        case .physicalNetwork:
            return String(localized: TeleportStrings.wifiDeviceUnavailableDetails)
        }
    }

    private func availableDetails(for device: CoreDeviceRecord, kind: DeviceKind) -> String {
        let pairingState = device.connectionProperties?.pairingState ?? "unknown"
        let developerMode = device.deviceProperties?.developerModeStatus ?? "unknown"
        let tunnelState = device.connectionProperties?.tunnelState

        if let tunnelState, kind == .physicalNetwork {
            return "\(transportLabel(for: kind)) · \(pairingState) · tunnel \(tunnelState) · dev mode \(developerMode)"
        }

        return "\(transportLabel(for: kind)) · \(pairingState) · dev mode \(developerMode)"
    }

    private func formattedOSVersion(for device: CoreDeviceRecord) -> String {
        let version = device.deviceProperties?.osVersionNumber ?? "iOS"
        if let build = device.deviceProperties?.osBuildUpdate {
            return "\(version) (\(build))"
        }

        return version
    }

    private func resolvedDeviceName(for device: CoreDeviceRecord, fallbackID: String) -> String {
        if let name = device.deviceProperties?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        {
            return name
        }

        if let marketingName = device.hardwareProperties?.marketingName?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !marketingName.isEmpty
        {
            return marketingName
        }

        if let deviceType = device.hardwareProperties?.deviceType?.trimmingCharacters(in: .whitespacesAndNewlines),
            !deviceType.isEmpty
        {
            return deviceType
        }

        return "iOS Device \(fallbackID.suffix(6))"
    }
}
