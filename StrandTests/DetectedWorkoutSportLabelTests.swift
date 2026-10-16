import XCTest
import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

/// #detected-workout-sport-precision: the confirmation card now labels a detected window with its
/// predicted sport instead of the generic "Workout". `.run` was originally held to a stricter bar
/// than `WorkoutTypeClassifier.classify`'s own general one, but the user explicitly walked that back
/// after seeing it in practice: "pas besoin d'une exigence très stricte, juste il faut vraiment que tu
/// arrives à le voir bien" — running needs to actually get SEEN reliably (recall), not filtered by an
/// extra margin on top of what the classifier already requires. `.run` now uses that same general
/// floor; `.strength` (muscu, a request the user has NOT walked back) and `.golf` (new, unvalidated)
/// keep their own stricter bars. `Repository.sportLabel(for:)` is the pure gate that decision runs
/// through; these pin it against the EXACT `WorkoutClassPrediction` numbers the existing
/// `WorkoutTypeClassifierTests`/`WorkoutTypeFeatureExtractorTests` fixtures produce (hand-computed from
/// `WorkoutTypeClassifier`'s published formula, not guessed), so a change to either the gate or the
/// classifier's weights that breaks this separation is caught here.
@MainActor
final class DetectedWorkoutSportLabelTests: XCTestCase {

    // MARK: - `sportLabel(for:)` — pure gate, no store

    /// Twin of `WorkoutTypeClassifierTests.testRunShapedWindow_dominantRunTicks_isClassifiedRun`'s
    /// fixture, scored by hand against `WorkoutTypeClassifier`'s published weights: run ≈ 0.958 vs. a
    /// cycle runner-up ≈ 0.55 — clears the (now general) run gate easily.
    func testCleanTickBackedRun_getsTheRunningLabel() {
        let prediction = WorkoutClassPrediction(
            predictedClass: .run, confidence: 0.67,
            scores: [.run: 0.9583, .walk: 0.0, .strength: 0.10, .cycle: 0.55, .ski: 0.50])
        XCTAssertEqual(Repository.sportLabel(for: prediction), "Running")
    }

    /// Twin of `WorkoutTypeClassifierTests.testRunShapedWindow_noTicks_fallsBackToHRAndMotion`'s
    /// fixture (no activity-class ticks at all — a WHOOP 4.0 capture): run ≈ 0.955 vs. a cycle
    /// runner-up ≈ 0.70 — proves the label isn't ONLY reachable when ticks are present.
    func testNoTickRunFallback_getsTheRunningLabel() {
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

    /// A run prediction that only just clears `WorkoutTypeClassifier.classify`'s own general
    /// 0.40/0.05 bar (the weakest possible prediction that still isn't `.other`) — since `.run` now
    /// shares that same floor, this MUST get the "Running" label, not fall back to generic. This is
    /// the exact case the user asked to fix: a run that is real but not textbook-clean must still
    /// get seen.
    func testWeakButRealRunPrediction_stillGetsTheRunningLabel() {
        let prediction = WorkoutClassPrediction(
            predictedClass: .run, confidence: 0.3,
            scores: [.run: 0.41, .walk: 0.10, .strength: 0.05, .cycle: 0.35, .ski: 0.20])
        XCTAssertEqual(Repository.sportLabel(for: prediction), "Running",
                       "run uses the same general floor as walk/cycle/ski now — recall over precision")
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

    /// `.strength` is held to the SAME asymmetric bar as `.run` (0.80/0.15), at the user's explicit
    /// request ("aussi de la muscu"). Twin of `WorkoutTypeClassifierTests.
    /// testHighHRLowCadenceWindow_isClassifiedStrength`'s fixture, scored by hand: strength = 1.0
    /// (every term maxes out) against a 0.70 ski runner-up — comfortably clears the bar.
    func testCleanHighHRStrength_clearsTheStrengthGate() {
        let prediction = WorkoutClassPrediction(
            predictedClass: .strength, confidence: 0.6,
            scores: [.run: 0.17, .walk: 0.0, .strength: 1.00, .cycle: 0.675, .ski: 0.70])
        XCTAssertEqual(Repository.sportLabel(for: prediction), "Strength")
    }

    /// Twin of `WorkoutTypeClassifierTests.testModerateHRBurstySets_isClassifiedStrength`'s fixture —
    /// a GENTLER lifting session, still comfortably clears the bar (0.91 score, 0.21 margin over ski).
    func testGentlerBurstyStrength_stillClearsTheStrengthGate() {
        let prediction = WorkoutClassPrediction(
            predictedClass: .strength, confidence: 0.5,
            scores: [.run: 0.0, .walk: 0.0, .strength: 0.91, .cycle: 0.508, .ski: 0.70])
        XCTAssertEqual(Repository.sportLabel(for: prediction), "Strength")
    }

    /// A strength prediction that clears the GENERAL 0.40/0.05 floor but not `.strength`'s own
    /// stricter 0.80/0.15 bar — must fall back to generic, same shape as the run equivalent above.
    func testWeakStrengthPrediction_fallsBackToGeneric() {
        let prediction = WorkoutClassPrediction(
            predictedClass: .strength, confidence: 0.3,
            scores: [.run: 0.1, .walk: 0.05, .strength: 0.55, .cycle: 0.2, .ski: 0.15])
        XCTAssertNil(Repository.sportLabel(for: prediction),
                     "0.55 clears the general 0.40 floor but not strength's own 0.80 one")
    }

    // MARK: - GOLF

    /// Twin of `WorkoutTypeClassifierTests.testLongerLighterRoundStillClassifiedGolf`'s fixture —
    /// a realistic round with meaningful standing-still time and a MODERATE (not fully-saturating)
    /// walk-tick share, scored by hand: golf ≈ 0.90 against a 0.70 walk runner-up (walk's own closest
    /// competing shape). Comfortably clears the gate (score ≥ 0.75, margin ≥ 0.15).
    func testRealisticRound_clearsTheGolfGate() {
        let prediction = WorkoutClassPrediction(
            predictedClass: .golf, confidence: 0.55,
            scores: [.run: 0.0, .walk: 0.70, .strength: 0.0, .cycle: 0.12, .ski: 0.0, .golf: 0.90])
        XCTAssertEqual(Repository.sportLabel(for: prediction), "Golf")
    }

    /// A golf prediction that clears the GENERAL floor but not golf's own wider 0.75/0.15 bar.
    func testWeakGolfPrediction_fallsBackToGeneric() {
        let prediction = WorkoutClassPrediction(
            predictedClass: .golf, confidence: 0.3,
            scores: [.run: 0.0, .walk: 0.60, .strength: 0.0, .cycle: 0.1, .ski: 0.0, .golf: 0.68])
        XCTAssertNil(Repository.sportLabel(for: prediction),
                     "a 0.08 margin over walk doesn't clear golf's 0.15 margin floor")
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
