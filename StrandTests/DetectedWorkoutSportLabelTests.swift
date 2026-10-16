import XCTest
import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

/// #detected-workout-sport-precision: the confirmation card now labels a detected window with its
/// predicted sport instead of the generic "Workout", but ONLY confidently enough — the user's explicit
/// ask was "hyper précis pour la course à pied" (never a wrong specific guess for running, even at the
/// cost of more runs falling back to "Workout"). `Repository.sportLabel(for:)` is the pure gate that
/// decision runs through; these pin it against the EXACT `WorkoutClassPrediction` numbers the existing
/// `WorkoutTypeClassifierTests`/`WorkoutTypeFeatureExtractorTests` fixtures produce (hand-computed from
/// `WorkoutTypeClassifier`'s published formula, not guessed), so a change to either the gate or the
/// classifier's weights that breaks this separation is caught here.
@MainActor
final class DetectedWorkoutSportLabelTests: XCTestCase {

    // MARK: - `sportLabel(for:)` — pure gate, no store

    /// Twin of `WorkoutTypeClassifierTests.testRunShapedWindow_dominantRunTicks_isClassifiedRun`'s
    /// fixture, scored by hand against `WorkoutTypeClassifier`'s published weights: run ≈ 0.958 vs. a
    /// cycle runner-up ≈ 0.55 — comfortably clears the run gate (score ≥ 0.85, margin ≥ 0.20).
    func testCleanTickBackedRun_clearsTheRunGate() {
        let prediction = WorkoutClassPrediction(
            predictedClass: .run, confidence: 0.67,
            scores: [.run: 0.9583, .walk: 0.0, .strength: 0.10, .cycle: 0.55, .ski: 0.50])
        XCTAssertEqual(Repository.sportLabel(for: prediction), "Running")
    }

    /// Twin of `WorkoutTypeClassifierTests.testRunShapedWindow_noTicks_fallsBackToHRAndMotion`'s
    /// fixture (no activity-class ticks at all — a WHOOP 4.0 capture): run ≈ 0.955 vs. a cycle
    /// runner-up ≈ 0.70, still comfortably inside the gate even with the weaker, tick-less fallback
    /// score — this is the case that proves the gate isn't ONLY reachable when ticks are present.
    func testNoTickRunFallback_stillClearsTheRunGate() {
        let prediction = WorkoutClassPrediction(
            predictedClass: .run, confidence: 0.51,
            scores: [.run: 0.955, .walk: 0.0, .strength: 0.20, .cycle: 0.70, .ski: 0.65])
        XCTAssertEqual(Repository.sportLabel(for: prediction), "Running")
    }

    /// Twin of `WorkoutTypeClassifierTests.testAmbiguousWindow_isOtherOrLowConfidence`'s fixture.
    /// `WorkoutTypeClassifier.classify` itself already resolves this to `.other` (its own
    /// `minPlausibleScore`/`minMargin` gate), so `sportLabel` must return nil regardless of the raw
    /// scores — `.other` carries no gate entry at all.
    func testAmbiguousWindow_classifiedAsOther_neverGetsASpecificLabel() {
        let prediction = WorkoutClassPrediction(
            predictedClass: .other, confidence: 0.2,
            scores: [.run: 0.1143, .walk: 0.05, .strength: 0.08, .cycle: 0.12, .ski: 0.09])
        XCTAssertNil(Repository.sportLabel(for: prediction))
    }

    /// A run score that is high in isolation but NOT held to the run-specific bar — e.g. a brisk-walk-
    /// shaped window where the classifier (hypothetically, or after a future retune) still predicts
    /// `.run` at a score just over the GENERAL 0.40/0.05 floor but well under the run-specific 0.85/0.20
    /// one. Must still fall back to the generic label: the whole point of the asymmetric gate is that
    /// clearing the general bar is NOT enough for `.run`.
    func testRunPredictionBelowTheRunSpecificBar_fallsBackToGeneric() {
        let prediction = WorkoutClassPrediction(
            predictedClass: .run, confidence: 0.3,
            scores: [.run: 0.55, .walk: 0.10, .strength: 0.05, .cycle: 0.45, .ski: 0.20])
        XCTAssertNil(Repository.sportLabel(for: prediction),
                     "0.55 clears the general 0.40 floor but not run's own 0.85 one")
    }

    /// A run score that clears the score floor but NOT the margin floor against a close cycle
    /// runner-up — the ambiguity a bare score threshold alone would miss.
    func testRunPredictionWithThinMargin_fallsBackToGeneric() {
        let prediction = WorkoutClassPrediction(
            predictedClass: .run, confidence: 0.6,
            scores: [.run: 0.90, .walk: 0.10, .strength: 0.05, .cycle: 0.80, .ski: 0.30])
        XCTAssertNil(Repository.sportLabel(for: prediction),
                     "a 0.10 margin over cycle doesn't clear run's 0.20 margin floor")
    }

    /// Twin of `WorkoutTypeClassifierTests.testLowHRWalk_isClassifiedWalk` — the general 0.40/0.05 gate
    /// (not run's stricter one) governs walk/cycle/strength/ski, and this fixture clears it easily.
    func testCleanWalk_getsTheWalkLabel() {
        let prediction = WorkoutClassPrediction(
            predictedClass: .walk, confidence: 0.55,
            scores: [.run: 0.05, .walk: 0.80, .strength: 0.10, .cycle: 0.20, .ski: 0.15])
        XCTAssertEqual(Repository.sportLabel(for: prediction), "Walking")
    }

    func testCleanCycle_getsTheCyclingLabel() {
        let prediction = WorkoutClassPrediction(
            predictedClass: .cycle, confidence: 0.5,
            scores: [.run: 0.2, .walk: 0.05, .strength: 0.15, .cycle: 0.75, .ski: 0.40])
        XCTAssertEqual(Repository.sportLabel(for: prediction), "Cycling")
    }

    func testCleanStrength_getsTheStrengthLabel() {
        let prediction = WorkoutClassPrediction(
            predictedClass: .strength, confidence: 0.45,
            scores: [.run: 0.1, .walk: 0.05, .strength: 0.70, .cycle: 0.2, .ski: 0.15])
        XCTAssertEqual(Repository.sportLabel(for: prediction), "Strength")
    }

    func testCleanSki_getsTheSkiingLabel() {
        let prediction = WorkoutClassPrediction(
            predictedClass: .ski, confidence: 0.45,
            scores: [.run: 0.2, .walk: 0.05, .strength: 0.15, .cycle: 0.4, .ski: 0.68])
        XCTAssertEqual(Repository.sportLabel(for: prediction), "Skiing")
    }

    // MARK: - `classifiedSport(for:)` / `saveDetectedWorkout` — end to end over a real store

    private func runBlock(_ start: Int, _ durS: Int) -> (hr: [HRSample], gravity: [GravitySample], steps: [StepSample]) {
        let hr = (0..<durS).map { HRSample(ts: start + $0, bpm: 160) }
        let gravity = (0..<durS).map { i in
            GravitySample(ts: start + i, x: (i % 2 == 0) ? 0 : 0.4, y: 0, z: 1)
        }
        let steps = (0..<durS).map { StepSample(ts: start + $0, counter: $0, activityClass: 2) }
        return (hr, gravity, steps)
    }

    /// End-to-end: a clean, dominant-run-tick window saved through the real `Repository` reads back
    /// with the "Running" label, not the generic "Workout" fallback — proving the store reads
    /// (`hrSamples`/`gravitySamplesUnion`/`stepSamplesUnion`) feed the classifier correctly, not just
    /// the pure gate in isolation.
    func testClassifiedSport_realRunWindow_resolvesToRunning() async throws {
        let deviceId = "my-whoop"
        let store = try await WhoopStore.inMemory()
        let start = Int(Date().timeIntervalSince1970) - 3_600
        let dur = 20 * 60
        let block = runBlock(start, dur)
        _ = try await store.insert(
            Streams(hr: block.hr, gravity: block.gravity, steps: block.steps), deviceId: deviceId)

        let repo = Repository(deviceId: deviceId)
        repo.setStoreForTesting(store)
        // `classifiedSport(for:)` resolves resting HR from the most recent nightly RHR on record
        // (same as `autoDetectCandidate`'s own `restingBpm`), NOT by deriving one from the bout
        // window itself — a single detected bout is by construction all-elevated, with no resting
        // baseline inside it. A real day always has this by the time the detector runs (the nightly
        // scoring pass writes it), so the test supplies the same thing directly.
        repo.days = [DailyMetric(day: "2026-01-01", totalSleepMin: nil, efficiency: nil, deepMin: nil,
                                 remMin: nil, lightMin: nil, disturbances: nil, restingHr: 60,
                                 avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)]

        let candidate = DetectedWorkout(startSec: start, endSec: start + dur,
                                        avgBpm: 160, peakBpm: 168, durationMin: 20)
        let sport = await repo.classifiedSport(for: candidate)
        XCTAssertEqual(sport, "Running")

        let saved = await repo.saveDetectedWorkout(candidate)
        XCTAssertTrue(saved)
        let rows = try await store.workouts(deviceId: deviceId, from: start - 1, to: start + dur + 1, limit: 10)
        XCTAssertEqual(rows.first?.sport, "Running",
                       "the persisted row must carry the SAME label the preview computed")
    }

    /// A window with no decoded streams at all (can't happen for a real detector candidate, but the
    /// extractor's nil path must still degrade to the generic label rather than crash or save nothing).
    func testClassifiedSport_noStreams_fallsBackToGenericWorkout() async throws {
        let deviceId = "my-whoop"
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: deviceId)
        repo.setStoreForTesting(store)

        let candidate = DetectedWorkout(startSec: 10_000, endSec: 10_900, avgBpm: 130, peakBpm: 150, durationMin: 15)
        let sport = await repo.classifiedSport(for: candidate)
        XCTAssertEqual(sport, "Workout")
    }
}
