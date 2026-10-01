import Foundation
import Observation
import SleepiCore

@MainActor public protocol HealthReading: AnyObject {
    func requestAccess() async throws
    func fetch() async throws -> HealthSnapshot
    func observe(_ update: @escaping @MainActor @Sendable () async -> Void)
}

@MainActor public protocol AudioCapturing: AnyObject {
    var isRecording: Bool { get }
    func start(directory: URL, remainingBytes: Int, onEvent: @escaping @MainActor @Sendable (SoundEvent) -> Void,
               onStatus: @escaping @MainActor @Sendable (String) -> Void) async throws
    func stop() async
    func play(_ url: URL, onEnded: @escaping @MainActor @Sendable () -> Void) throws
    func stopPlayback()
}

@Observable @MainActor public final class AppModel {
    public var state = LocalState()
    public var snapshot = HealthSnapshot(samples: [])
    public var nights: [SleepNight] = []
    public var isDemo: Bool
    public var isLoading = false
    public var error: String?
    public var healthStatus = "Connect Apple Health to see your nights."
    public var recordingStatus = "Sound is off"
    public var showSettings = false
    public var showStartSheet = false
    public var showOnboarding = false
    public var selectedTab = 0
    public var selectedNightID: Date?
    public var isStarting = false
    public var isStopping = false
    public var playingID: UUID?
    public var onSessionChanged: (@MainActor (TonightSession?) -> Void)?
    public var onMorning: (@MainActor (SleepNight) async -> Bool)?
    public var requestNotifications: (@MainActor () async -> Bool)?
    public var onSnapshot: (@MainActor (SleepNight?) -> Void)?
    public var onLocalStoreReady: (@MainActor () -> Void)?
    private var store: LocalRepository?
    private var health: (any HealthReading)?
    private var audio: (any AudioCapturing)?
    private var canSave = false
    private var loaded = false
    private var captureGeneration: UUID?

    public init(demo: Bool = false, health: (any HealthReading)? = nil, audio: (any AudioCapturing)? = nil, directory: URL? = nil) {
        isDemo = demo; self.health = health; self.audio = audio
        if demo { loadDemo() }
        else {
            do {
                let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("sleepi", isDirectory: true)
                store = try LocalRepository(directory: base)
            } catch { self.error = "Local storage is unavailable: \(error.localizedDescription)" }
        }
    }
    public var selectedNight: SleepNight? { nights.first { $0.id == selectedNightID } ?? nights.last }
    public var activeSession: TonightSession? { state.sessions.last { $0.end == nil } }
    public var audioAvailable: Bool { audio != nil && !isDemo }
    public var usedBytes: Int { state.sounds.reduce(0) { $0 + $1.byteCount } }
    public var selectedSounds: [SoundEvent] {
        guard let night = selectedNight else { return state.sounds.sorted { $0.start > $1.start } }
        return state.sounds.filter { $0.start >= night.windowStart && $0.start < night.windowEnd }.sorted { $0.start < $1.start }
    }
    public func load() async {
        guard !loaded else { return }; loaded = true
        guard !isDemo else { return }
        do {
            if let store {
                state = try await store.load(); canSave = true
                // A process restart is not evidence of uninterrupted recording. End the marker.
                for i in state.sessions.indices where state.sessions[i].end == nil {
                    state.sessions[i].end = .now
                    state.sessions[i].status = "Interrupted · end time recovered on launch"
                }
                onSessionChanged?(nil)
                try await store.removeOrphanClips(keeping: Set(state.sounds.compactMap(\.fileName)))
                await pruneClips()
                await persist()
            }
        } catch { canSave = false; self.error = "Couldn’t open your library. Existing data was left unchanged. \(error.localizedDescription)" }
        if canSave { onLocalStoreReady?() }
        showOnboarding = !state.settings.onboardingComplete
        health?.observe { [weak self] in await self?.refresh(background: true) }
        if state.settings.onboardingComplete { await refresh() }
    }
    public func loadDemo() {
        snapshot = DemoData.snapshot(); nights = NightBuilder.build(samples: snapshot.samples)
        state.settings.onboardingComplete = true
        healthStatus = "Example data · no connection to Apple Health"
    }
    public func connect() async {
        guard let health else { return }
        do { try await health.requestAccess(); await refresh() }
        catch { self.error = "Health couldn’t be opened: \(error.localizedDescription)" }
    }
    public func completeOnboarding() async {
        state.settings.onboardingComplete = true; showOnboarding = false; await persist()
    }
    public func refresh(background: Bool = false) async {
        guard !isDemo, !isLoading, let health, state.settings.onboardingComplete || showOnboarding else { return }
        isLoading = true; defer { isLoading = false }
        do {
            let result = try await health.fetch()
            snapshot = result; nights = NightBuilder.build(samples: result.samples)
            onSnapshot?(nights.last)
            healthStatus = nights.isEmpty ? "No readable Apple Watch sleep yet. Data may be unavailable or access may be off." : "From Apple Watch · refreshed \(result.fetchedAt.formatted(date: .omitted, time: .shortened))"
            if background, state.settings.morningNotifications, let night = nights.last,
               let wake = night.lastSleep, wake < Date.now.addingTimeInterval(-3600), wake > Date.now.addingTimeInterval(-18 * 3600),
               state.lastNotifiedNight != night.id, await onMorning?(night) == true {
                state.lastNotifiedNight = night.id; await persist()
            }
        } catch {
            snapshot = HealthSnapshot(samples: []); nights = [] // Do not masquerade stale data as fresh permission.
            onSnapshot?(nil)
            healthStatus = "Health is unavailable right now. Unlock your phone and try again."
            if !background { self.error = error.localizedDescription }
        }
    }
    public func startTonight(sound: Bool) async {
        guard activeSession == nil, !isStarting, !isStopping else { return }
        guard isDemo || canSave else { error = "Resolve the local storage issue before starting a night."; return }
        isStarting = true; defer { isStarting = false }
        audio?.stopPlayback(); playingID = nil
        if sound {
            guard let audio, let store, !isDemo else { error = "Sound recording requires the iPhone app."; return }
            await pruneClips()
            let remaining = state.settings.clipBudgetBytes - usedBytes
            guard remaining >= 160_000 else { error = "Saved clips fill your storage budget. Remove a clip before recording."; return }
            do {
                let generation = UUID(); captureGeneration = generation
                try await audio.start(directory: await store.directory.appendingPathComponent("Clips"), remainingBytes: min(remaining, 20_000_000), onEvent: { [weak self] event in
                    guard let self, self.captureGeneration == generation else { return }
                    self.state.sounds.append(event)
                    Task { await self.persist() }
                }, onStatus: { [weak self] status in self?.recordingStatus = status })
            } catch { self.error = "Sound couldn’t start: \(error.localizedDescription)"; return }
        }
        let session = TonightSession(requestedAudio: sound, status: sound ? "Sound recording requested" : "In-bed marker only")
        state.sessions.append(session); await persist()
        if !canSave && !isDemo { await audio?.stop(); state.sessions.removeAll { $0.id == session.id }; return }
        onSessionChanged?(session); showStartSheet = false
    }
    public func stopTonight() async {
        guard !isStarting, !isStopping else { return }
        isStopping = true; defer { isStopping = false }
        await audio?.stop()
        if let index = state.sessions.lastIndex(where: { $0.end == nil }) {
            state.sessions[index].end = .now; state.sessions[index].status = "Ended"
        }
        recordingStatus = "Sound is off"; onSessionChanged?(nil); await persist()
    }
    public func toggleStar(_ event: SoundEvent) async {
        if let i = state.sounds.firstIndex(where: { $0.id == event.id }) { state.sounds[i].starred.toggle(); await persist() }
    }
    public func toggleNotMe(_ event: SoundEvent) async {
        if let i = state.sounds.firstIndex(where: { $0.id == event.id }) { state.sounds[i].notMe.toggle(); await persist() }
    }
    public func play(_ event: SoundEvent) async {
        if playingID == event.id { audio?.stopPlayback(); playingID = nil; return }
        guard let name = event.fileName, let store, let audio else { return }
        do { try audio.play(try await store.clipURL(name), onEnded: { [weak self] in self?.playingID = nil }); playingID = event.id }
        catch { self.error = "Clip playback failed: \(error.localizedDescription)"; playingID = nil }
    }
    public func removeClip(_ event: SoundEvent) async {
        guard let store else { return }
        do {
            if playingID == event.id { audio?.stopPlayback(); playingID = nil }
            if let name = event.fileName { try await store.deleteClip(name) }
            state.sounds.removeAll { $0.id == event.id }; await persist()
        } catch { self.error = "Couldn’t delete this clip: \(error.localizedDescription)" }
    }
    public func pruneClips() async {
        guard let store, canSave else { return }
        let plan = ClipRetention.plan(events: state.sounds, now: .now, days: state.settings.retentionDays, budget: state.settings.clipBudgetBytes, reservation: 0)
        for event in state.sounds where plan.deleteIDs.contains(event.id) {
            do {
                if let name = event.fileName { try await store.deleteClip(name) }
                if let i = state.sounds.firstIndex(where: { $0.id == event.id }) { state.sounds[i].fileName = nil; state.sounds[i].byteCount = 0 }
            } catch { self.error = "Some expired clips couldn’t be deleted. \(error.localizedDescription)" }
        }
        await persist()
    }
    public func saveJournal(_ journal: NightJournal) async {
        state.journals.removeAll { $0.nightID == journal.nightID }; state.journals.append(journal); await persist()
    }
    public func persist() async {
        guard !isDemo, canSave, let store else { return }
        do { try await store.save(state) }
        catch { canSave = false; self.error = "Your change couldn’t be saved. Reopen sleepi after checking storage. \(error.localizedDescription)" }
    }
    public func importMotion(_ recording: MotionRecording) async {
        guard recording.isValid, !isDemo, canSave else { return }
        if let cutoff = state.ignoreWatchRecordsBefore, recording.start < cutoff { return }
        state.motionNights.removeAll { $0.id == recording.id }; state.motionNights.append(recording)
        state.motionNights.removeAll { $0.end < Date.now.addingTimeInterval(-90 * 86400) }
        await persist()
    }
    public func importWatchMarker(id: UUID, start: Date, end: Date?) async {
        guard !isDemo, canSave, start <= .now, end.map({ $0 >= start && $0 <= .now }) ?? true else { return }
        if let cutoff = state.ignoreWatchRecordsBefore, start < cutoff { return }
        if let i = state.sessions.firstIndex(where: { $0.id == id }) {
            if let end { state.sessions[i].end = end; state.sessions[i].status = "Ended on Watch" }
        } else {
            // A Watch marker is a journal entry, never a command to start the phone microphone.
            var marker = TonightSession(start: start, requestedAudio: false, status: "Watch in-bed marker")
            marker.id = id; marker.end = end ?? start; state.sessions.append(marker)
        }
        await persist()
    }
    public func wakeCandidates(for night: SleepNight) -> [WakeCandidate] {
        let motion = state.motionNights.filter { $0.start < night.windowEnd && $0.end > night.windowStart }.flatMap(\.epochs)
        let heart = snapshot.vitals.filter { $0.kind == .heartRate }.sorted { $0.date < $1.date }
        let epochs = motion.filter { $0.start >= night.windowStart && $0.start < night.windowEnd }.map { epoch in
            let stage = night.segments.first { $0.start <= epoch.start && $0.end >= epoch.start.addingTimeInterval(30) }?.stage
            let recent = heart.last { $0.date <= epoch.start && epoch.start.timeIntervalSince($0.date) <= 90 }
            let prior = heart.last { $0.date < epoch.start.addingTimeInterval(-90) && epoch.start.timeIntervalSince($0.date) <= 300 }
            let rise = recent.flatMap { r in prior.map { r.value - $0.value } }
            return WakeEvidence(start: epoch.start, stage: stage, movement: epoch.sampleCount >= 1000 ? epoch.meanMovement : nil, heartRateRise: rise)
        }
        return WakeExperiment.candidates(epochs)
    }
    public func reviewWake(_ candidate: WakeCandidate, confirmed: Bool) async {
        state.wakeReviews.removeAll { $0.start == candidate.start && $0.end == candidate.end }
        state.wakeReviews.append(WakeReview(start: candidate.start, end: candidate.end, confirmed: confirmed)); await persist()
    }
    public func deleteLocalData() async {
        await stopTonight(); audio?.stopPlayback(); playingID = nil
        captureGeneration = nil
        do {
            try await store?.deleteAll(); state = LocalState(); canSave = store != nil
            state.ignoreWatchRecordsBefore = .now
            await persist()
            snapshot = HealthSnapshot(samples: []); nights = []; showSettings = false; showOnboarding = true
            onSnapshot?(nil)
        } catch { self.error = "Deletion could not finish: \(error.localizedDescription)" }
    }
    public func vital(_ kind: VitalKind, night: SleepNight) -> (value: Double, baseline: Double?, count: Int)? {
        guard let start = night.firstSleep, let end = night.lastSleep else { return nil }
        let values = snapshot.vitals.filter { $0.kind == kind && $0.date >= start && $0.date <= end }.map(\.value)
        guard let value = Insights.median(values) else { return nil }
        let priorNights = nights.filter { $0.windowStart < night.windowStart }.suffix(30)
        let nightlyValues = priorNights.compactMap { n -> Double? in
            guard let start = n.firstSleep, let end = n.lastSleep else { return nil }
            return Insights.median(snapshot.vitals.filter { $0.kind == kind && $0.date >= start && $0.date <= end }.map(\.value))
        }
        return (value, nightlyValues.count >= 7 ? Insights.median(nightlyValues) : nil, values.count)
    }
}
