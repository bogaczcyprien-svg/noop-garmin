import SwiftUI
import StrandDesign
import StrandAnalytics

/// Fork, restored (see `AutoWorkoutDetector.swift`'s header and `DetectedWorkoutReconciliationTests`'
/// own doc comment: the confirmation card has always been the ONLY path meant to turn a detected
/// window into a visible workout — a no-confirmation auto-save variant existed briefly and was
/// reverted after false positives, which is why `AppModel.evaluateAutoWorkoutSave` doesn't exist
/// anywhere in this codebase despite stale comments elsewhere still naming it; those are corrected
/// alongside this file).
///
/// Shows the single best sustained-elevated-HR window the opt-in detector found (`Repository.
/// autoDetectCandidate`), labeled with its predicted sport (`Repository.classifiedSport(for:)`) when
/// the classifier clears its per-class bar, or the generic "workout" wording otherwise — never a
/// wrong specific guess dressed up as fact. "Save" persists it under that same label (`Repository.
/// saveDetectedWorkout`, which re-runs the SAME classification so the saved row can never disagree
/// with what this card just showed — one resolver, not two readouts of the same fact); "Dismiss"
/// records the span so it never re-prompts (`Repository.dismissDetectedSuggestion`).
///
/// Self-hiding: renders nothing while there is no candidate, so it costs no space on an install that
/// never trips the detector. Unlike the Planned Training card this sits beside, there is no persistent
/// "nothing detected" shell — "no workout happened" is not news worth a permanent line on Today.
struct DetectedWorkoutSuggestionCard: View {
    @EnvironmentObject var repo: Repository
    @State private var candidate: DetectedWorkout?
    @State private var predictedSport: String?
    @State private var saving = false

    var body: some View {
        Group {
            if let candidate {
                cardBody(candidate)
            }
        }
        .task { await load() }
    }

    private func cardBody(_ candidate: DetectedWorkout) -> some View {
        StrandCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: icon(for: predictedSport))
                        .foregroundStyle(StrandPalette.effortColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Looks like \(sportWording(predictedSport))")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(timeRangeLabel(candidate))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                }

                HStack(spacing: 16) {
                    statPair("Duration", "\(candidate.durationMin) min")
                    statPair("Avg HR", "\(candidate.avgBpm) bpm")
                    statPair("Peak HR", "\(candidate.peakBpm) bpm")
                }

                HStack(spacing: 12) {
                    NoopButton("Save", systemImage: "checkmark", kind: .primary) {
                        Task { await save(candidate) }
                    }
                    .disabled(saving)
                    NoopButton("Dismiss", kind: .tertiary) {
                        dismiss(candidate)
                    }
                    .disabled(saving)
                }
            }
        }
    }

    private func sportWording(_ predictedSport: String?) -> String {
        guard let predictedSport else { return "a workout" }
        switch predictedSport {
        case "Running":  return "a run"
        case "Walking":  return "a walk"
        case "Cycling":  return "a ride"
        case "Strength": return "a strength session"
        case "Skiing":   return "a ski session"
        default:         return "a workout"
        }
    }

    private func icon(for predictedSport: String?) -> String {
        switch predictedSport {
        case "Running":  return "figure.run"
        case "Walking":  return "figure.walk"
        case "Cycling":  return "figure.outdoor.cycle"
        case "Strength": return "dumbbell.fill"
        case "Skiing":   return "figure.skiing.downhill"
        default:         return "waveform.path.ecg"
        }
    }

    private func timeRangeLabel(_ w: DetectedWorkout) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        let start = Date(timeIntervalSince1970: TimeInterval(w.startSec))
        let end = Date(timeIntervalSince1970: TimeInterval(w.endSec))
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    private func statPair(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(StrandPalette.textTertiary)
            Text(value).font(StrandFont.caption).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private func save(_ w: DetectedWorkout) async {
        saving = true
        defer { saving = false }
        _ = await repo.saveDetectedWorkout(w)
        await load()
    }

    private func dismiss(_ w: DetectedWorkout) {
        repo.dismissDetectedSuggestion(w)
        Task { await load() }
    }

    /// Fetches the current best candidate and, when one exists, its predicted sport — in that order,
    /// so a view that renders mid-fetch never shows stale label text for a different window.
    private func load() async {
        let next = await repo.autoDetectCandidate()
        guard let next else {
            candidate = nil
            predictedSport = nil
            return
        }
        let sport = await repo.classifiedSport(for: next)
        candidate = next
        predictedSport = sport
    }
}
