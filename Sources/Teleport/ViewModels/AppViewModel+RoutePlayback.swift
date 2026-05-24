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
        let runTotalTimeSeconds: Double
        let runPaceStrategy: RoutePlaybackRunPaceStrategy
        let runFatigueFraction: Double
    }

    private struct RunPaceSample {
        let cumulativeDistanceMeters: Double
        let speedMetersPerSecond: Double
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
            runTotalTimeSeconds: routePlaybackRunTotalTimeSeconds,
            runPaceStrategy: routePlaybackRunPaceStrategy,
            runFatigueFraction: routePlaybackRunFatigueFraction
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
        case .running:
            delays = simulatedRunPaceDelays(
                distances: distances,
                totalTimeSeconds: pacing.runTotalTimeSeconds,
                strategy: pacing.runPaceStrategy,
                fatigue: pacing.runFatigueFraction,
                routeID: route.id,
                startingAfter: waypointIndex
            )
        case .recorded, .fixedInterval, .fixedSpeed:
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
        case .running:
            let distanceMeters = start.coordinate.distance(to: end.coordinate)
            guard distanceMeters > 0, let route = loadedRoute, route.totalDistanceMeters > 0 else {
                return 0
            }

            return pacing.runTotalTimeSeconds * distanceMeters / route.totalDistanceMeters
        }
    }

    private func simulatedRunPaceDelays(
        distances: [Double],
        totalTimeSeconds: Double,
        strategy: RoutePlaybackRunPaceStrategy,
        fatigue: Double,
        routeID: UUID,
        startingAfter waypointIndex: Int
    ) -> [TimeInterval] {
        guard totalTimeSeconds > 0 else {
            return distances.map { _ in 0 }
        }

        let totalDistanceMeters = distances.reduce(0) { $0 + max($1, 0) }
        guard totalDistanceMeters > 0 else {
            return distances.map { _ in 0 }
        }

        let samples = simulatedRunPaceSamples(
            totalTimeSeconds: totalTimeSeconds,
            totalDistanceMeters: totalDistanceMeters,
            strategy: strategy,
            fatigue: fatigue,
            seed: routePlaybackVariationSeed(routeID: routeID, startingAfter: waypointIndex)
        )

        guard !samples.isEmpty else {
            return distances.map { _ in 0 }
        }

        var previousDistance = 0.0
        return distances.map { distance in
            guard distance > 0 else {
                return 0.0
            }

            let targetDistance = previousDistance + distance
            let startTime = simulatedRunTime(
                forDistance: previousDistance,
                samples: samples,
                totalTimeSeconds: totalTimeSeconds
            )
            let endTime = simulatedRunTime(
                forDistance: min(targetDistance, totalDistanceMeters),
                samples: samples,
                totalTimeSeconds: totalTimeSeconds
            )
            previousDistance = targetDistance
            return max(0, endTime - startTime)
        }
    }

    private func simulatedRunPaceSamples(
        totalTimeSeconds: Double,
        totalDistanceMeters: Double,
        strategy: RoutePlaybackRunPaceStrategy,
        fatigue: Double,
        seed: UInt64
    ) -> [RunPaceSample] {
        guard totalTimeSeconds > 0, totalDistanceMeters > 0 else {
            return []
        }

        let dt = 1.0
        let waveAmplitude = 0.05
        let waveTau = 45.0
        let noiseAmplitude = 0.02
        let warmupSeconds = 25.0
        let minimumShapeFactor = 0.25
        let sampleCount = max(1, Int(round(totalTimeSeconds / dt)))
        let averageSpeed = totalDistanceMeters / totalTimeSeconds
        let clampedFatigue = min(
            max(fatigue, routePlaybackRunFatigueRange.lowerBound), routePlaybackRunFatigueRange.upperBound)
        let ouDecay = exp(-dt / waveTau)
        let ouSigma = waveAmplitude * sqrt(1.0 - ouDecay * ouDecay)

        var generator = SeededRandomNumberGenerator(seed: seed)
        var ou = 0.0
        var rawSpeeds: [Double] = []
        rawSpeeds.reserveCapacity(sampleCount)

        for index in 0..<sampleCount {
            let time = Double(index) * dt
            let progress = time / totalTimeSeconds
            let strategyTrend: Double
            switch strategy {
            case .negative:
                strategyTrend = 1.0 + 0.05 * (progress - 0.5) * 2
            case .positive:
                strategyTrend = 1.0 - 0.05 * (progress - 0.5) * 2
            case .even:
                strategyTrend = 1.0
            }

            let trend = strategyTrend * (1.0 - clampedFatigue * progress)
            let warmupProgress = min(max(time / warmupSeconds, 0), 1)
            let warmup = 0.72 + 0.28 * pow(warmupProgress, 0.7)

            if index > 0 {
                ou = ouDecay * ou + ouSigma * generator.nextGaussian()
            }
            let highFrequencyNoise = noiseAmplitude * generator.nextGaussian()
            let shape = max(minimumShapeFactor, trend * warmup * (1.0 + ou + highFrequencyNoise))
            rawSpeeds.append(shape * averageSpeed)
        }

        let rawDistance = rawSpeeds.reduce(0, +) * dt
        guard rawDistance > 0 else {
            return []
        }

        let scale = totalDistanceMeters / rawDistance
        var cumulativeDistance = 0.0
        return rawSpeeds.map { rawSpeed in
            let speed = rawSpeed * scale
            cumulativeDistance += speed * dt
            return RunPaceSample(cumulativeDistanceMeters: cumulativeDistance, speedMetersPerSecond: speed)
        }
    }

    private func simulatedRunTime(
        forDistance distanceMeters: Double,
        samples: [RunPaceSample],
        totalTimeSeconds: Double
    ) -> TimeInterval {
        guard distanceMeters > 0 else {
            return 0
        }

        guard let sampleIndex = samples.firstIndex(where: { $0.cumulativeDistanceMeters >= distanceMeters }) else {
            return totalTimeSeconds
        }

        let sample = samples[sampleIndex]
        let previousDistance = sampleIndex > 0 ? samples[sampleIndex - 1].cumulativeDistanceMeters : 0
        let previousTime = Double(sampleIndex)
        let distanceWithinSample = distanceMeters - previousDistance
        let sampleDistance = max(sample.cumulativeDistanceMeters - previousDistance, Double.leastNonzeroMagnitude)
        let sampleFraction = min(max(distanceWithinSample / sampleDistance, 0), 1)
        return min(totalTimeSeconds, previousTime + sampleFraction)
    }

    private func routePlaybackVariationSeed(routeID: UUID, startingAfter waypointIndex: Int) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(routeID)
        hasher.combine(waypointIndex)
        hasher.combine(Int((routePlaybackRunTotalTimeSeconds * 10).rounded()))
        hasher.combine(routePlaybackRunPaceStrategy.rawValue)
        hasher.combine(Int((routePlaybackRunFatigueFraction * 1000).rounded()))
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
