import Foundation
import OSLog

extension AppViewModel {
    func importGPXRoute(from url: URL) async {
        stopRoutePlayback(resetToReadyState: false)
        clearRouteBuilderDraft()

        let accessedSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)
            let parser = GPXRouteParser()
            let route = try parser.parse(
                data: data,
                fallbackName: url.deletingPathExtension().lastPathComponent
            )

            loadedRoute = route
            routePlaybackState = .ready

            if let startCoordinate = loadedRouteStartDisplayCoordinate {
                suppressPickedLocationPin = false
                latitudeText = String(format: "%.6f", startCoordinate.latitude)
                longitudeText = String(format: "%.6f", startCoordinate.longitude)
            }

            statusMessage = .localized(
                TeleportStrings.loadedRoute(route.name, pointCount: route.pointCount)
            )
        } catch {
            loadedRoute = nil
            let message = UserFacingText.localized(
                TeleportStrings.failedToImportGPX(error.localizedDescription)
            )
            routePlaybackState = .failed(message)
            statusMessage = message
        }
    }

    func clearLoadedRoute() {
        stopRoutePlayback(resetToReadyState: false)
        loadedRoute = nil
        clearRouteBuilderDraft()
        routePlaybackState = .idle
        statusMessage = .localized(TeleportStrings.clearedLoadedRoute)
    }

    func startRoutePlayback() async {
        stopMovementControl(commitCurrentCoordinateToTextFields: false)

        guard let route = loadedRoute else {
            let message = UserFacingText.localized(TeleportStrings.noRouteLoaded)
            routePlaybackState = .failed(message)
            statusMessage = message
            return
        }

        guard route.waypoints.count > 1 else {
            let message = UserFacingText.localized(TeleportStrings.routeRequiresAtLeastTwoPoints)
            routePlaybackState = .failed(message)
            statusMessage = message
            return
        }

        guard routePlaybackAvailable else {
            let message = UserFacingText.localized(TeleportStrings.routePlaybackRequiresConnection)
            routePlaybackState = .failed(message)
            statusMessage = message
            return
        }

        switch routePlaybackState {
        case .playing:
            return
        case .idle, .ready, .paused, .completed, .failed:
            break
        }

        do {
            let target = try await resolvedSimulationTargetForPlayback()
            let initialProgress = playbackStartProgress(for: route)
            routePlaybackState = .playing(initialProgress)

            routePlaybackTask?.cancel()
            routePlaybackGeneration += 1
            let generation = routePlaybackGeneration
            routePlaybackTask = Task {
                await runRoutePlayback(
                    route: route,
                    initialProgress: initialProgress,
                    target: target,
                    generation: generation
                )
            }
        } catch {
            handleRoutePlaybackError(error)
        }
    }

    func pauseRoutePlayback() {
        guard case .playing(let progress) = routePlaybackState else {
            return
        }

        routePlaybackState = .paused(progress)
        routePlaybackTask?.cancel()
        routePlaybackTask = nil
        routePlaybackGeneration += 1

        if let routeName = loadedRoute?.name {
            statusMessage = .localized(TeleportStrings.pausedRoute(routeName))
        }
    }

    func stopRoutePlayback(resetToReadyState: Bool = true) {
        routePlaybackTask?.cancel()
        routePlaybackTask = nil
        routePlaybackGeneration += 1

        guard loadedRoute != nil else {
            routePlaybackState = .idle
            return
        }

        if resetToReadyState {
            routePlaybackState = .ready

            if let routeName = loadedRoute?.name {
                statusMessage = .localized(TeleportStrings.stoppedRoute(routeName))
            }
        }
    }

    private struct SimulationPlaybackTarget {
        let device: Device
        let service: LocationSimulationService
    }

    private struct PlaybackInterpolationStep {
        let coordinate: LocationCoordinate
        let delaySeconds: TimeInterval
        let stepDistanceMeters: Double
        let traveledDistanceMeters: Double
        let progressWaypointIndex: Int
    }

    private struct RoutePlaybackSegmentTiming {
        let startIndex: Int
        let endIndex: Int
        let delaySeconds: TimeInterval
    }

    private struct RoutePlaybackPacingSnapshot: Equatable {
        let timingMode: RoutePlaybackTimingMode
        let speedMultiplier: Double
        let fixedIntervalSeconds: Double
        let travelSpeedMetersPerSecond: Double
        let speedVariationFraction: Double
    }

    private var routePlaybackTaskDelayBeforeRestartSeconds: UInt64 {
        10_000_000
    }

    private var routePlaybackPacingSnapshot: RoutePlaybackPacingSnapshot {
        RoutePlaybackPacingSnapshot(
            timingMode: routePlaybackTimingMode,
            speedMultiplier: routePlaybackSpeedMultiplier,
            fixedIntervalSeconds: routePlaybackFixedIntervalSeconds,
            travelSpeedMetersPerSecond: routePlaybackTravelSpeedMetersPerSecond,
            speedVariationFraction: routePlaybackSpeedVariationFraction
        )
    }

    private func handleRoutePlaybackError(_ error: Error) {
        routePlaybackTask?.cancel()
        routePlaybackTask = nil

        let message = UserFacingText.verbatim(error.localizedDescription)
        routePlaybackState = .failed(message)
        statusMessage = message
        TeleportLog.simulation.error("Route playback failed: \(error.localizedDescription, privacy: .public)")
    }

    private func resolvedSimulationTargetForPlayback() async throws -> SimulationPlaybackTarget {
        guard let selectedDevice else {
            throw ServiceError.invalidSelection
        }

        let device: Device
        if selectedDevice.kind.isPhysicalDevice && connectionState == .connected {
            device = selectedDevice
        } else if let refreshedDevice = await refreshedDeviceForAction(selectedDevice, stateTarget: .simulation) {
            device = refreshedDevice
        } else {
            throw ServiceError.invalidSelection
        }

        guard let service = registry.service(for: device.kind) else {
            throw ServiceError.unavailable(
                String(localized: TeleportStrings.noServiceAvailable(for: device.kind.rawValue))
            )
        }

        if device.kind.isPhysicalDevice && showsUSBApprovalReminder {
            showsUSBPrivilegeNotice = true
            throw ServiceError.unavailable(String(localized: TeleportStrings.reviewAdministratorApproval))
        }

        let hasActiveSimulationSession = await service.hasActiveSimulationSession()
        if device.kind.isPhysicalDevice && !hasActiveSimulationSession {
            simulationState = .starting
            statusMessage = .localized(TeleportStrings.startingPhysicalDeviceSimulation)
        }

        return SimulationPlaybackTarget(device: device, service: service)
    }

    private func playbackStartProgress(for route: SimulatedRoute) -> RoutePlaybackProgress {
        switch routePlaybackState {
        case .paused(let progress) where progress.routeID == route.id:
            return progress
        case .completed where loadedRoute?.id == route.id:
            return makeRoutePlaybackProgress(for: route, waypointIndex: 0)
        case .playing(let progress) where progress.routeID == route.id:
            return progress
        case .idle, .ready, .paused, .completed, .failed, .playing:
            return makeRoutePlaybackProgress(for: route, waypointIndex: 0)
        }
    }

    private func runRoutePlayback(
        route: SimulatedRoute,
        initialProgress: RoutePlaybackProgress,
        target: SimulationPlaybackTarget,
        generation: Int
    ) async {
        TeleportLog.simulation.info(
            "Starting route playback for \(route.name, privacy: .public) on \(target.device.logLabel, privacy: .public)"
        )

        defer {
            if routePlaybackGeneration == generation {
                routePlaybackTask = nil
            }
        }

        do {
            var currentProgress = initialProgress
            let waypoints = route.waypoints
            let totalRouteDistanceMeters = route.totalDistanceMeters
            var elapsedPlaybackSeconds = currentProgress.elapsedPlaybackSeconds
            let playbackStartTraveledDistanceMeters = currentProgress.playbackStartTraveledDistanceMeters

            if currentProgress.waypointIndex == 0 || currentProgress.currentCoordinate == nil {
                let startCoordinate = ChinaCoordinateTransform.displayCoordinate(for: waypoints[0].coordinate)
                try await applyDisplayedSimulationCoordinate(startCoordinate, on: target.device, using: target.service)
                currentProgress = makeRoutePlaybackProgress(for: route, waypointIndex: 0)
                routePlaybackState = .playing(currentProgress)
            }

            if currentProgress.waypointIndex >= waypoints.count - 1 {
                routePlaybackState = .completed(currentProgress)
                statusMessage = .localized(TeleportStrings.completedRoute(route.name))
                return
            }

            let segmentTimings = routePlaybackSegmentTimings(
                for: route,
                startingAfter: currentProgress.waypointIndex,
                pacing: routePlaybackPacingSnapshot
            )

            for segmentTiming in segmentTimings {
                let smoothedSteps = smoothedPlaybackSteps(
                    from: waypoints[segmentTiming.startIndex],
                    to: waypoints[segmentTiming.endIndex],
                    totalDelaySeconds: segmentTiming.delaySeconds,
                    traveledDistanceBeforeSegment: currentProgress.traveledDistanceMeters,
                    totalRouteDistanceMeters: totalRouteDistanceMeters,
                    nextWaypointIndex: segmentTiming.endIndex,
                    route: route
                )

                for step in smoothedSteps {
                    if step.delaySeconds > 0 {
                        try await Task.sleep(nanoseconds: UInt64(step.delaySeconds * 1_000_000_000))
                        elapsedPlaybackSeconds += step.delaySeconds
                    }

                    try Task.checkCancellation()

                    let displayedCoordinate = ChinaCoordinateTransform.displayCoordinate(for: step.coordinate)
                    try await applyDisplayedSimulationCoordinate(
                        displayedCoordinate,
                        on: target.device,
                        using: target.service,
                        moving: true
                    )

                    try Task.checkCancellation()

                    currentProgress = makeRoutePlaybackProgress(
                        for: route,
                        waypointIndex: step.progressWaypointIndex,
                        displayedCoordinate: displayedCoordinate,
                        traveledDistanceMeters: step.traveledDistanceMeters,
                        totalDistanceMeters: totalRouteDistanceMeters,
                        playbackStartTraveledDistanceMeters: playbackStartTraveledDistanceMeters,
                        elapsedPlaybackSeconds: elapsedPlaybackSeconds,
                        currentSpeedMetersPerSecond: step.delaySeconds > 0
                            ? step.stepDistanceMeters / step.delaySeconds : nil
                    )
                    routePlaybackState = .playing(currentProgress)
                }

                statusMessage = .localized(
                    TeleportStrings.playingRoute(
                        route.name,
                        pointNumber: segmentTiming.endIndex + 1,
                        totalPoints: waypoints.count
                    )
                )
            }

            routePlaybackState = .completed(currentProgress)
            statusMessage = .localized(TeleportStrings.completedRoute(route.name))
            TeleportLog.simulation.info(
                "Completed route playback for \(route.name, privacy: .public) on \(target.device.logLabel, privacy: .public)"
            )
        } catch is CancellationError {
            TeleportLog.simulation.debug("Route playback cancelled")
        } catch {
            handleRoutePlaybackError(error)
        }
    }

    private func routeSegmentDelay(from start: RouteWaypoint, to end: RouteWaypoint) -> TimeInterval {
        playbackSegmentDelay(from: start, to: end)
    }

    func restartActiveRoutePlaybackAfterPacingChange() {
        guard case .playing(let progress) = routePlaybackState,
            let route = loadedRoute,
            progress.routeID == route.id,
            let targetTask = routePlaybackTask
        else {
            return
        }

        targetTask.cancel()
        routePlaybackTask = nil
        routePlaybackGeneration += 1
        let generation = routePlaybackGeneration
        routePlaybackState = .playing(progress)
        routePlaybackTask = Task {
            do {
                try await Task.sleep(nanoseconds: routePlaybackTaskDelayBeforeRestartSeconds)
                let target = try await resolvedSimulationTargetForPlayback()
                await runRoutePlayback(
                    route: route,
                    initialProgress: progress,
                    target: target,
                    generation: generation
                )
            } catch is CancellationError {
            } catch {
                handleRoutePlaybackError(error)
            }
        }
    }

    private func routePlaybackSegmentTimings(
        for route: SimulatedRoute,
        startingAfter waypointIndex: Int,
        pacing: RoutePlaybackPacingSnapshot
    ) -> [RoutePlaybackSegmentTiming] {
        let waypoints = route.waypoints
        guard waypoints.count > 1, waypointIndex < waypoints.count - 1 else {
            return []
        }

        let segmentIndexes = (waypointIndex + 1)..<waypoints.count
        let distances = segmentIndexes.map { nextIndex in
            waypoints[nextIndex - 1].coordinate.distance(to: waypoints[nextIndex].coordinate)
        }

        let delays: [TimeInterval]
        switch pacing.timingMode {
        case .fixedSpeed:
            delays = variedFixedSpeedDelays(
                distances: distances,
                averageSpeedMetersPerSecond: pacing.travelSpeedMetersPerSecond,
                variationFraction: pacing.speedVariationFraction,
                routeID: route.id,
                startingAfter: waypointIndex
            )
        case .recorded, .fixedInterval:
            delays = segmentIndexes.map { nextIndex in
                routeSegmentDelay(
                    from: waypoints[nextIndex - 1],
                    to: waypoints[nextIndex],
                    pacing: pacing
                )
            }
        }

        return zip(segmentIndexes, delays).map { nextIndex, delay in
            RoutePlaybackSegmentTiming(startIndex: nextIndex - 1, endIndex: nextIndex, delaySeconds: delay)
        }
    }

    private func routeSegmentDelay(
        from start: RouteWaypoint,
        to end: RouteWaypoint,
        pacing: RoutePlaybackPacingSnapshot
    ) -> TimeInterval {
        switch pacing.timingMode {
        case .fixedInterval:
            return pacing.fixedIntervalSeconds
        case .recorded:
            if let startTimestamp = start.timestamp,
                let endTimestamp = end.timestamp
            {
                let timestampDelay = endTimestamp.timeIntervalSince(startTimestamp)
                if timestampDelay > 0 {
                    return min(timestampDelay / pacing.speedMultiplier, maximumRouteSegmentDelaySeconds)
                }
            }

            if let expectedTravelTime = end.expectedTravelTime,
                expectedTravelTime > 0
            {
                return min(expectedTravelTime / pacing.speedMultiplier, maximumRouteSegmentDelaySeconds)
            }

            return movementTickIntervalSeconds
        case .fixedSpeed:
            let distanceMeters = start.coordinate.distance(to: end.coordinate)
            guard distanceMeters > 0, pacing.travelSpeedMetersPerSecond > 0 else {
                return 0
            }

            return distanceMeters / pacing.travelSpeedMetersPerSecond
        }
    }

    private func variedFixedSpeedDelays(
        distances: [Double],
        averageSpeedMetersPerSecond: Double,
        variationFraction: Double,
        routeID: UUID,
        startingAfter waypointIndex: Int
    ) -> [TimeInterval] {
        guard averageSpeedMetersPerSecond > 0 else {
            return distances.map { _ in 0 }
        }

        let positiveDistance = distances.reduce(0) { $0 + max($1, 0) }
        guard positiveDistance > 0 else {
            return distances.map { _ in 0 }
        }

        let targetDuration = positiveDistance / averageSpeedMetersPerSecond
        let variation = min(max(variationFraction, 0), routePlaybackSpeedVariationRange.upperBound)
        let speeds = variedRouteSpeeds(
            segmentCount: distances.count,
            averageSpeedMetersPerSecond: averageSpeedMetersPerSecond,
            variationFraction: variation,
            seed: routePlaybackVariationSeed(routeID: routeID, startingAfter: waypointIndex)
        )
        let rawDurations = zip(distances, speeds).map { distance, speed in
            guard distance > 0, speed > 0 else {
                return 0.0
            }

            return distance / speed
        }
        let rawDuration = rawDurations.reduce(0, +)
        guard rawDuration > 0 else {
            return distances.map { _ in 0 }
        }

        let durationScale = targetDuration / rawDuration
        return rawDurations.map { $0 * durationScale }
    }

    private func variedRouteSpeeds(
        segmentCount: Int,
        averageSpeedMetersPerSecond: Double,
        variationFraction: Double,
        seed: UInt64
    ) -> [Double] {
        guard segmentCount > 0 else {
            return []
        }

        guard variationFraction > 0 else {
            return Array(repeating: averageSpeedMetersPerSecond, count: segmentCount)
        }

        var generator = SeededRandomNumberGenerator(seed: seed)
        var deviation = 0.0
        let meanReversion = 0.28
        let noiseScale = averageSpeedMetersPerSecond * variationFraction * 0.45
        let maxDeviation = averageSpeedMetersPerSecond * variationFraction
        let minimumSpeed = max(averageSpeedMetersPerSecond * 0.20, 0.1)

        return (0..<segmentCount).map { _ in
            deviation += -meanReversion * deviation + generator.nextGaussian() * noiseScale
            deviation = min(max(deviation, -maxDeviation), maxDeviation)
            return max(minimumSpeed, averageSpeedMetersPerSecond + deviation)
        }
    }

    private func routePlaybackVariationSeed(routeID: UUID, startingAfter waypointIndex: Int) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(routeID)
        hasher.combine(waypointIndex)
        hasher.combine(Int((routePlaybackTravelSpeedMetersPerSecond * 100).rounded()))
        hasher.combine(Int((routePlaybackSpeedVariationFraction * 100).rounded()))
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    private func makeRoutePlaybackProgress(for route: SimulatedRoute, waypointIndex: Int) -> RoutePlaybackProgress {
        let clampedIndex = min(max(waypointIndex, 0), max(route.waypoints.count - 1, 0))
        let displayedCoordinate =
            route.waypoints.indices.contains(clampedIndex)
            ? ChinaCoordinateTransform.displayCoordinate(for: route.waypoints[clampedIndex].coordinate)
            : nil

        let traveledDistanceMeters: Double
        if clampedIndex > 0 {
            traveledDistanceMeters = zip(
                route.waypoints.prefix(clampedIndex), route.waypoints.dropFirst().prefix(clampedIndex)
            )
            .reduce(0) { total, pair in
                total + pair.0.coordinate.distance(to: pair.1.coordinate)
            }
        } else {
            traveledDistanceMeters = 0
        }

        let totalDistanceMeters = route.totalDistanceMeters

        return RoutePlaybackProgress(
            routeID: route.id,
            waypointIndex: clampedIndex,
            waypointCount: route.waypoints.count,
            currentCoordinate: displayedCoordinate,
            traveledDistanceMeters: traveledDistanceMeters,
            totalDistanceMeters: totalDistanceMeters
        )
    }

    private func makeRoutePlaybackProgress(
        for route: SimulatedRoute,
        waypointIndex: Int,
        displayedCoordinate: LocationCoordinate,
        traveledDistanceMeters: Double,
        totalDistanceMeters: Double,
        playbackStartTraveledDistanceMeters: Double,
        elapsedPlaybackSeconds: TimeInterval,
        currentSpeedMetersPerSecond: Double?
    ) -> RoutePlaybackProgress {
        let sessionDistanceMeters = max(0, traveledDistanceMeters - playbackStartTraveledDistanceMeters)
        let averageSpeedMetersPerSecond =
            elapsedPlaybackSeconds > 0
            ? sessionDistanceMeters / elapsedPlaybackSeconds : nil

        return RoutePlaybackProgress(
            routeID: route.id,
            waypointIndex: waypointIndex,
            waypointCount: route.waypoints.count,
            currentCoordinate: displayedCoordinate,
            traveledDistanceMeters: traveledDistanceMeters,
            totalDistanceMeters: totalDistanceMeters,
            playbackStartTraveledDistanceMeters: playbackStartTraveledDistanceMeters,
            elapsedPlaybackSeconds: elapsedPlaybackSeconds,
            currentSpeedMetersPerSecond: currentSpeedMetersPerSecond,
            averageSpeedMetersPerSecond: averageSpeedMetersPerSecond
        )
    }

    private func smoothedPlaybackSteps(
        from start: RouteWaypoint,
        to end: RouteWaypoint,
        totalDelaySeconds: TimeInterval,
        traveledDistanceBeforeSegment: Double,
        totalRouteDistanceMeters: Double,
        nextWaypointIndex: Int,
        route: SimulatedRoute
    ) -> [PlaybackInterpolationStep] {
        let segmentDistanceMeters = start.coordinate.distance(to: end.coordinate)
        let timeStepCount =
            totalDelaySeconds > 0
            ? max(1, Int(ceil(totalDelaySeconds / routePlaybackSmoothingIntervalSeconds)))
            : 1
        let distanceStepCount =
            segmentDistanceMeters > 0
            ? max(1, Int(ceil(segmentDistanceMeters / maximumRouteStepDistanceMeters)))
            : 1
        let stepCount = max(timeStepCount, distanceStepCount)
        let perStepDelay = stepCount > 0 ? totalDelaySeconds / Double(stepCount) : 0

        return (1...stepCount).map { stepIndex in
            let fraction = Double(stepIndex) / Double(stepCount)
            let coordinate = start.coordinate.interpolated(to: end.coordinate, fraction: fraction)
            let traveledDistanceMeters = min(
                traveledDistanceBeforeSegment + segmentDistanceMeters * fraction,
                totalRouteDistanceMeters
            )
            let progressWaypointIndex = stepIndex == stepCount ? nextWaypointIndex : max(nextWaypointIndex - 1, 0)

            return PlaybackInterpolationStep(
                coordinate: coordinate,
                delaySeconds: perStepDelay,
                stepDistanceMeters: segmentDistanceMeters / Double(stepCount),
                traveledDistanceMeters: traveledDistanceMeters,
                progressWaypointIndex: progressWaypointIndex
            )
        }
    }
}

fileprivate struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func nextUnitDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func nextGaussian() -> Double {
        let first = max(nextUnitDouble(), Double.leastNonzeroMagnitude)
        let second = nextUnitDouble()
        return sqrt(-2 * log(first)) * cos(2 * Double.pi * second)
    }
}
