import Foundation
import Observation
import SleepiCore

/// Health refuses reads while the iPhone is locked, and for a moment after unlocking ("Protected health data is
/// inaccessible"). It's temporary: keep what's on screen and try again shortly.
public struct HealthLocked: Error, Sendable { public init() {} }

@MainActor public protocol HealthReading: AnyObject {
    func requestAccess() async throws
    func fetch() async throws -> HealthSnapshot
    func observe(_ update: @escaping @MainActor @Sendable () async -> Void)
}

@MainActor public protocol AudioCapturing: AnyObject {
    var isRecording: Bool { get }
    func start(directory: URL, remainingBytes: Int, onEvent: @escaping @MainActor @Sendable (SoundEvent) -> Void,
               onStats: @escaping @MainActor @Sendable (SoundSessionStats) -> Void,
               saveClips: Bool,
               onEpoch: @escaping @MainActor @Sendable (PhoneEpoch) -> Void,
               onStatus: @escaping @MainActor @Sendable (String) -> Void) async throws
    func stop() async
    func play(_ url: URL, onEnded: @escaping @MainActor @Sendable () -> Void) throws
    func stopPlayback()
}

/// The iPhone's own night signals for phone-only nights: motion counts (phone picked up or moved) and phone-use events.
@MainActor public protocol PhoneSensing: AnyObject {
    func start(onMotion: @escaping @MainActor @Sendable (PhoneEpoch) -> Void, onEvent: @escaping @MainActor @Sendable (PhoneEvent) -> Void)
    /// Stops, and returns motion epochs read back from the system recorder to fill gaps, when it has any.
    func stop(nightStart: Date) async -> [PhoneEpoch]
}

/// A night started or ended on this iPhone, for the Watch to mirror.
public enum SessionSyncEvent: Sendable {
    case started(TonightSession), ended(TonightSession)
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
    public var onSessionSync: (@MainActor (SessionSyncEvent) -> Void)?
    public var onGentleWakeChanged: (@MainActor () -> Void)?
    /// A paired Apple Watch with sleepi installed, so gentle wake can be offered on iPhone too.
    public var watchAvailable = false
    /// The wake time to pre-fill on iPhone: your usual Apple Watch wake-up for tomorrow, when known.
    public var suggestedGentleWake: Date? { GentleWakePolicy.suggestion(now: .now, picked: [:], usual: usualWake)?.date }
    public var onMorning: (@MainActor (SleepNight) async -> Bool)?
    public var requestNotifications: (@MainActor () async -> Bool)?
    public var onSnapshot: (@MainActor (SleepNight?) -> Void)?
    public var onLocalStoreReady: (@MainActor () -> Void)?
    private var store: LocalRepository?
    private var health: (any HealthReading)?
    private var audio: (any AudioCapturing)?
    private var phone: (any PhoneSensing)?
    /// Phone-only nights, newest last. Stored in their own files.
    public var phoneNights: [PhoneNight] = []
    private var lastPhoneSave = Date.distantPast
    public var onPhoneNightReady: (@MainActor () async -> Void)?
    private var canSave = false
    private var loaded = false
    private var captureGeneration: UUID?
    private var libraryFailed = false
    private var lockedRetries = 0

    public init(demo: Bool = false, health: (any HealthReading)? = nil, audio: (any AudioCapturing)? = nil, phone: (any PhoneSensing)? = nil, directory: URL? = nil) {
        isDemo = demo; self.health = health; self.audio = audio; self.phone = phone
        if demo { loadDemo() }
        else {
            do {
                let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("sleepi", isDirectory: true)
                store = try LocalRepository(directory: base)
            } catch { self.error = "Local storage is unavailable: \(error.localizedDescription)" }
        }
    }
    /// Usual Apple Watch wake-up per weekday, sent to the Watch to pre-fill gentle wake (Apple's schedule isn't readable).
    public var usualWake: [Int: Int] { UsualWake.byWeekday(nights: nights, now: .now) }
    public var gentleWake: GentleWakeSettings { state.settings.gentleWake ?? GentleWakeSettings() }
    public var wakeLogs: [WakeLog] { (state.wakeLogs ?? []).sorted { $0.windowStart > $1.windowStart } }
    /// An edit made on this iPhone: saved and sent to the Watch.
    public func setGentleWake(windowMinutes: Int, sensitivity: WakeSensitivity) async {
        let edited = GentleWakeSettings(windowMinutes: windowMinutes, sensitivity: sensitivity, updatedAt: .now)
        guard edited.windowMinutes != gentleWake.windowMinutes || edited.sensitivity != gentleWake.sensitivity else { return }
        state.settings.gentleWake = edited; await persist(); onGentleWakeChanged?()
    }
    /// An edit made on the Watch. The newer edit wins, so an older message can't undo a change made here.
    public func importGentleWake(_ settings: GentleWakeSettings) async {
        guard !isDemo, canSave, settings.updatedAt > gentleWake.updatedAt, settings.updatedAt <= Date.now.addingTimeInterval(60) else { return }
        state.settings.gentleWake = GentleWakeSettings(windowMinutes: settings.windowMinutes, sensitivity: settings.sensitivity, updatedAt: settings.updatedAt)
        await persist()
    }
    public func importWakeLog(_ log: WakeLog) async {
        guard !isDemo, canSave, log.isValid else { return }
        if let cutoff = state.ignoreWatchRecordsBefore, log.windowStart < cutoff { return }
        var logs = (state.wakeLogs ?? []).filter { $0.id != log.id }
        logs.append(log)
        state.wakeLogs = Array(logs.sorted { $0.windowStart < $1.windowStart }.suffix(30))
        await persist()
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
                // A process restart is not evidence of uninterrupted recording, so iPhone nights end here. A night
                // started on the Watch is still running there: keep it, but any iPhone sound it carried has stopped.
                for i in state.sessions.indices where state.sessions[i].end == nil {
                    if state.sessions[i].origin == .watch, state.sessions[i].start > Date.now.addingTimeInterval(-18 * 3600) {
                        if state.sessions[i].requestedAudio {
                            state.sessions[i].requestedAudio = false
                            state.sessions[i].status = "Started on Watch · sound stopped when sleepi restarted"
                        }
                        continue
                    }
                    state.sessions[i].end = .now
                    state.sessions[i].status = state.sessions[i].origin == .watch ? "No end received from Watch" : "Interrupted · end time recovered on launch"
                }
                onSessionChanged?(activeSession)
                try await store.removeOrphanClips(keeping: Set(state.sounds.compactMap(\.fileName)))
                migrateDefaultTags()
                // A phone night still open after a restart: the recording died with the process, so it ends at its last data.
                phoneNights = (try? await store.loadPhoneNights()) ?? []
                for i in phoneNights.indices where phoneNights[i].end == nil {
                    phoneNights[i].end = phoneNights[i].epochs.last.map { $0.start.addingTimeInterval(PhoneNightRule.epoch) } ?? phoneNights[i].start
                    phoneNights[i].events.append(PhoneEvent(.listeningStopped, at: phoneNights[i].end!))
                    phoneNights[i].recalculate()
                    try? await store.savePhoneNight(phoneNights[i])
                }
                // Older builds excluded everything from backup; now only unstarred clips are.
                for event in state.sounds { if let name = event.fileName { try? await store.setClipBackedUp(name, event.starred) } }
                await pruneClips()
                await persist()
                if libraryFailed { libraryFailed = false; self.error = nil }
            }
        } catch {
            // The app also loads at launch without a scene (HealthKit or Watch wakes), possibly before first unlock when
            // the library is unreadable. Allow the scene's load() to retry instead of staying broken until relaunch.
            canSave = false; loaded = false; libraryFailed = true
            self.error = "Couldn’t open your library. Existing data was left unchanged. \(error.localizedDescription)"
        }
        if canSave { onLocalStoreReady?() }
        showOnboarding = !state.settings.onboardingComplete
        health?.observe { [weak self] in await self?.refresh(background: true) }
        if state.settings.onboardingComplete { await refresh() }
    }
    public func loadDemo() {
        snapshot = DemoData.snapshot(); nights = NightBuilder.build(samples: snapshot.samples)
        state.settings.onboardingComplete = true; watchAvailable = true
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
            lockedRetries = 0
            snapshot = result; nights = NightBuilder.build(samples: result.samples)
            recomputeTagLinks()
            onSnapshot?(nights.last)
            healthStatus = nights.isEmpty ? (watchAvailable ? "No readable Apple Watch sleep yet. Data may be unavailable or access may be off." : "No sleep stages in Health. sleepi reads stages recorded by an Apple Watch.") : "From Apple Watch · refreshed \(result.fetchedAt.formatted(date: .omitted, time: .shortened))"
            if background, state.settings.morningNotifications, let night = nights.last,
               let wake = night.lastSleep, wake < Date.now.addingTimeInterval(-3600), wake > Date.now.addingTimeInterval(-18 * 3600),
               state.lastNotifiedNight != night.id, await onMorning?(night) == true {
                state.lastNotifiedNight = night.id; await persist()
            }
        } catch is HealthLocked {
            // Scene activation can run before the unlock makes Health readable. Not the user's problem: no alert,
            // keep the current nights, and retry a few times while in the foreground.
            healthStatus = "Waiting for Health to become readable after unlock."
            if !background, lockedRetries < 3 {
                lockedRetries += 1
                Task { [weak self] in try? await Task.sleep(for: .seconds(3)); await self?.refresh() }
            }
            return
        } catch {
            snapshot = HealthSnapshot(samples: []); nights = [] // Do not masquerade stale data as fresh permission.
            onSnapshot?(nil)
            healthStatus = "Health is unavailable right now. Unlock your phone and try again."
            if !background { self.error = error.localizedDescription }
        }
    }
    /// `sound` saves highlight clips; `phoneTracking` listens all night for levels (and watches for phone use) to
    /// estimate the night without a Watch. Either one turns the microphone on.
    public func startTonight(sound: Bool, gentleWake: Date? = nil, phoneTracking: Bool = false, phoneOnly: Bool = false) async {
        guard activeSession == nil, !isStarting, !isStopping else { return }
        guard isDemo || canSave else { error = "Resolve the local storage issue before starting a night."; return }
        isStarting = true; defer { isStarting = false }
        audio?.stopPlayback(); playingID = nil
        let micOn = sound || phoneTracking
        if micOn { guard await beginCapture(saveClips: sound) else { return } }
        var session = TonightSession(requestedAudio: micOn, status: sound ? "Sound recording requested" : phoneTracking ? "Listening for sound levels" : "In-bed marker only")
        if phoneTracking {
            var night = PhoneNight(start: session.start)
            night.alongsideWatch = (watchAvailable && !phoneOnly) ? true : nil
            phoneNights.append(night); session.phoneNightID = night.id
            try? await store?.savePhoneNight(night); lastPhoneSave = .now
            phone?.start(onMotion: { [weak self] epoch in self?.recordPhone(epoch: epoch) },
                         onEvent: { [weak self] event in self?.recordPhone(event: event) })
        }
        session.origin = .phone
        if let gentleWake, watchAvailable, gentleWake > Date.now.addingTimeInterval(5 * 60) { session.gentleWakeRequested = gentleWake }
        state.sessions.append(session); await persist()
        if !canSave && !isDemo { await audio?.stop(); state.sessions.removeAll { $0.id == session.id }; return }
        onSessionChanged?(session); onSessionSync?(.started(session)); showStartSheet = false
    }
    /// Adds sound to a night that's already running, such as one started on the Watch. Consent is this foreground tap.
    public func addSoundToTonight() async {
        guard let index = state.sessions.lastIndex(where: { $0.end == nil }), !state.sessions[index].requestedAudio,
              !isStarting, !isStopping else { return }
        isStarting = true; defer { isStarting = false }
        audio?.stopPlayback(); playingID = nil
        guard await beginCapture() else { return }
        state.sessions[index].requestedAudio = true; state.sessions[index].status = "Sound recording requested"
        await persist(); onSessionChanged?(state.sessions[index])
    }
    private var activePhoneNightIndex: Int? { phoneNights.lastIndex { $0.end == nil } }
    private func recordPhone(epoch: PhoneEpoch) {
        guard let i = activePhoneNightIndex else { return }
        phoneNights[i].merge(epoch); savePhoneNightIfDue(i)
    }
    private func recordPhone(event: PhoneEvent) {
        guard let i = activePhoneNightIndex else { return }
        phoneNights[i].events.append(event); savePhoneNightIfDue(i)
    }
    private func savePhoneNightIfDue(_ i: Int) {
        guard Date.now.timeIntervalSince(lastPhoneSave) >= 600, let store else { return }
        lastPhoneSave = .now
        let night = phoneNights[i]
        Task { try? await store.savePhoneNight(night) }
    }
    private func endPhoneNight(id: UUID, at end: Date) async {
        guard let i = phoneNights.firstIndex(where: { $0.id == id }), phoneNights[i].end == nil else { return }
        let fill = await phone?.stop(nightStart: phoneNights[i].start) ?? []
        for epoch in fill { phoneNights[i].merge(epoch) }
        phoneNights[i].end = end
        phoneNights[i].recalculate()
        try? await store?.savePhoneNight(phoneNights[i])
        recomputeTagLinks()
        if phoneNights[i].alongsideWatch != true, state.settings.morningNotifications { await onPhoneNightReady?() }
    }
    public func recalculatePhoneNights() async {
        for i in phoneNights.indices where phoneNights[i].end != nil {
            phoneNights[i].recalculate(); try? await store?.savePhoneNight(phoneNights[i])
        }
        recomputeTagLinks()
    }
    private func beginCapture(saveClips: Bool = true) async -> Bool {
        guard let audio, let store, !isDemo else { error = "Sound recording requires the iPhone app."; return false }
        await pruneClips()
        let remaining = state.settings.clipBudgetBytes - usedBytes
        guard remaining >= 160_000 else { error = "Saved clips fill your storage budget. Remove a clip before recording."; return false }
        do {
            let generation = UUID(); captureGeneration = generation
            try await audio.start(directory: await store.directory.appendingPathComponent("Clips"), remainingBytes: min(remaining, 20_000_000), onEvent: { [weak self] event in
                guard let self, self.captureGeneration == generation else { return }
                self.state.sounds.append(event)
                Task { await self.persist() }
            }, onStats: { [weak self] stats in
                guard let self, self.captureGeneration == generation,
                      let i = self.state.sessions.lastIndex(where: \.requestedAudio) else { return } // the night this capture belongs to
                self.state.sessions[i].soundStats = stats
                Task { await self.persist() }
            }, saveClips: saveClips, onEpoch: { [weak self] epoch in
                guard let self, self.captureGeneration == generation else { return }
                self.recordPhone(epoch: epoch)
            }, onStatus: { [weak self] status in self?.recordingStatus = status })
            return true
        } catch { self.error = "Sound couldn’t start: \(error.localizedDescription)"; return false }
    }
    public func stopTonight() async {
        guard !isStarting, !isStopping else { return }
        isStopping = true; defer { isStopping = false }
        guard let index = state.sessions.lastIndex(where: { $0.end == nil }) else {
            await audio?.stop(); recordingStatus = "Sound is off"; onSessionChanged?(nil); return
        }
        await finishSession(at: index, end: .now, status: "Ended")
        onSessionSync?(.ended(state.sessions[index]))
    }
    private func finishSession(at index: Int, end: Date, status: String) async {
        if let phoneID = state.sessions[index].phoneNightID { await endPhoneNight(id: phoneID, at: end) }
        if index == state.sessions.lastIndex(where: { $0.end == nil }) { await audio?.stop(); recordingStatus = "Sound is off" }
        state.sessions[index].end = end; state.sessions[index].status = status
        onSessionChanged?(activeSession); await persist()
    }
    public func toggleStar(_ event: SoundEvent) async {
        guard let i = state.sounds.firstIndex(where: { $0.id == event.id }) else { return }
        state.sounds[i].starred.toggle()
        if let name = state.sounds[i].fileName { try? await store?.setClipBackedUp(name, state.sounds[i].starred) }
        await persist()
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
        recomputeTagLinks()
    }
    public func journal(for night: SleepNight) -> NightJournal? { journal(nightID: night.id) }
    /// Diary entries are keyed by the night's date, so they work the same on Watch nights and phone nights.
    public func journal(nightID: Date) -> NightJournal? { state.journals.last { $0.nightID == nightID } }
    /// Morning card: a rating or a chip saves right away, so the card can be one or two taps or skipped.
    public func setRating(_ rating: Int?, nightID: Date) async {
        var entry = journal(nightID: nightID) ?? NightJournal(nightID: nightID)
        entry.rating = rating.map { min(5, max(1, $0)) }
        await saveJournal(entry)
    }
    public func toggleTag(_ tag: JournalTag, nightID: Date) async {
        var entry = journal(nightID: nightID) ?? NightJournal(nightID: nightID)
        if entry.tagIDs.contains(tag.id) { entry.tagIDs.remove(tag.id) } else { entry.tagIDs.insert(tag.id) }
        await saveJournal(entry)
    }

    // MARK: Tags: rename keeps the id (and so the history); hide, reorder, merge.
    public var visibleTags: [JournalTag] { state.tags.filter { $0.hidden != true } }
    public func addTag(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.tags.append(JournalTag(name: trimmed)); await persist()
    }
    public func setHidden(_ tag: JournalTag, _ hidden: Bool) async {
        guard let i = state.tags.firstIndex(where: { $0.id == tag.id }) else { return }
        state.tags[i].hidden = hidden ? true : nil; await persist()
    }
    public func moveTagUp(_ tag: JournalTag) async {
        guard let i = state.tags.firstIndex(where: { $0.id == tag.id }), i > 0 else { return }
        state.tags.swapAt(i, i - 1); await persist()
    }
    /// Every night tagged with `tag` becomes tagged with `target`, then `tag` is removed.
    public func merge(_ tag: JournalTag, into target: JournalTag) async {
        guard tag.id != target.id else { return }
        for i in state.journals.indices where state.journals[i].tagIDs.contains(tag.id) {
            state.journals[i].tagIDs.remove(tag.id); state.journals[i].tagIDs.insert(target.id)
        }
        state.tags.removeAll { $0.id == tag.id }; await persist(); recomputeTagLinks()
    }
    /// Libraries from before the sleep-diary chips still had the original six untouched defaults: rename them in
    /// place (keeping any history) and add the new ones. Libraries whose tags were edited are left alone.
    private func migrateDefaultTags() {
        guard state.tagsVersion == nil else { return }
        state.tagsVersion = 2
        let old = ["Late caffeine", "Alcohol", "Late meal", "Movement", "Stress", "Reading"]
        guard state.tags.map(\.name) == old else { return }
        let renames = ["Late caffeine": "Caffeine after 2 pm", "Late meal": "Late meal (within 3 h of bed)", "Movement": "Hard exercise late", "Stress": "Stressed"]
        for i in state.tags.indices {
            if let name = renames[state.tags[i].name] { state.tags[i].name = name }
            if state.tags[i].name == "Reading" { state.tags[i].hidden = true }
        }
        state.tags += ["Nap", "Unwell"].map(JournalTag.init)
    }

    // MARK: Linked results (refs/11 §1)
    /// Recomputed each time notes are saved or Health refreshes, on device. Seeded from the data so the same nights
    /// always give the same answer.
    public private(set) var tagStatuses: [UUID: TagStatus] = [:]
    public func sleepingHeartRate(for night: SleepNight) -> Double? {
        let asleep = night.segments.filter(\.stage.isAsleep)
        let values = snapshot.vitals.filter { reading in reading.kind == .heartRate && asleep.contains { $0.start <= reading.date && reading.date < $0.end } }.map(\.value)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    public func toFallAsleep(for night: SleepNight) -> TimeInterval? { inBed(for: night)?.toFallAsleep ?? markerToFirstSleep(for: night) }
    // MARK: Phone-only nights on screen
    /// Phone nights shown on Last Night and Trends: finished, and not recorded with the hidden test switch.
    public var visiblePhoneNights: [PhoneNight] { phoneNights.filter { $0.end != nil && $0.alongsideWatch != true } }
    /// Watch nights win: phone nights appear only when there are no Watch nights to show.
    public var showsPhoneNights: Bool { nights.isEmpty && !visiblePhoneNights.isEmpty }
    public var selectedPhoneNight: PhoneNight? {
        guard showsPhoneNights else { return nil }
        return visiblePhoneNights.first { $0.nightID == selectedNightID } ?? visiblePhoneNights.last
    }
    /// Test switch comparison: phone estimate vs Apple's sleep on the same night (refs: phone-only note 2, section C).
    public struct PhoneComparison: Identifiable, Sendable {
        public var id: Date
        public var fellAsleepDifference: TimeInterval?
        public var wokeDifference: TimeInterval?
        public var timeAsleepDifference: TimeInterval?
        public var phoneWakeUps: Int
        public var watchWakeUps: Int
    }
    public var phoneComparisons: [PhoneComparison] {
        phoneNights.filter { $0.alongsideWatch == true && $0.estimate != nil }.compactMap { phoneNight -> PhoneComparison? in
            guard let e = phoneNight.estimate, let watch = nights.first(where: { $0.id == phoneNight.nightID }) else { return nil }
            let first = watch.firstSleep ?? watch.windowStart, last = watch.lastSleep ?? watch.windowEnd
            let longWakes = watch.segments.filter { s in s.stage == .awake && s.seconds >= 300 && s.start >= first && s.end <= last }
            return PhoneComparison(id: phoneNight.nightID,
                                   fellAsleepDifference: e.fellAsleep.flatMap { p in watch.firstSleep.map { p.timeIntervalSince($0) } },
                                   wokeDifference: e.wokeForGood.flatMap { p in watch.lastSleep.map { p.timeIntervalSince($0) } },
                                   timeAsleepDifference: e.timeAsleep.map { $0 - watch.asleepSeconds },
                                   phoneWakeUps: e.wakeUps.filter { $0.end.timeIntervalSince($0.start) >= 300 }.count, watchWakeUps: longWakes.count)
        }
    }
    public func recomputeTagLinks() {
        let leftOut = leftOutNights
        let calendar = Calendar.current
        if showsPhoneNights {
            // No Watch nights: link tags to the phone estimate (time asleep and wake-ups only).
            let rows: [TagNight] = visiblePhoneNights.compactMap { night in
                guard let entry = journal(nightID: night.nightID), let e = night.estimate else { return nil }
                var measures: [TagMeasure: Double] = [.wakeUps: Double(e.wakeUps.count)]
                if let asleep = e.timeAsleep { measures[.totalSleep] = asleep }
                if let rating = entry.rating { measures[.rating] = Double(rating) }
                let evening = calendar.component(.weekday, from: night.nightID)
                return TagNight(weekend: evening == 6 || evening == 7, tags: entry.tagIDs, measures: measures)
            }
            evaluateTagLinks(rows); return
        }
        let rows: [TagNight] = nights.compactMap { night in
            guard !leftOut.contains(night.id), let entry = journal(for: night) else { return nil } // unreviewed nights aren't a control group
            var measures: [TagMeasure: Double] = [.totalSleep: night.asleepSeconds, .wakeUps: Double(night.interruptions.count)]
            if let fall = toFallAsleep(for: night) { measures[.toFallAsleep] = fall }
            if let heart = sleepingHeartRate(for: night) { measures[.sleepingHeartRate] = heart }
            if let rating = entry.rating { measures[.rating] = Double(rating) }
            let evening = calendar.component(.weekday, from: night.windowStart) // the night's evening: Fri (6), Sat (7) are weekend
            return TagNight(weekend: evening == 6 || evening == 7, tags: entry.tagIDs, measures: measures)
        }
        evaluateTagLinks(rows)
    }
    private func evaluateTagLinks(_ rows: [TagNight]) {
        let tags = state.tags.map(\.id), seed = UInt64(rows.count) &* 0x9E37 &+ UInt64(state.journals.count)
        tagLinkGeneration += 1
        let generation = tagLinkGeneration
        // Thousands of shuffles per tag: off the main thread, and only the latest request is kept.
        Task.detached(priority: .utility) {
            var generator = SplitMix64(seed: seed)
            let statuses = TagLinks.evaluate(nights: rows, tags: tags, generator: &generator)
            await MainActor.run { [weak self] in
                guard let self, self.tagLinkGeneration == generation else { return }
                self.tagStatuses = statuses
            }
        }
    }
    private var tagLinkGeneration = 0

    // MARK: Export (refs/11 §2): one row per night of sleepi's own data, shared through the share sheet.
    public var exportCSV: String {
        let names = Dictionary(uniqueKeysWithValues: state.tags.map { ($0.id, $0.name) })
        let rows = nights.map { night -> NightExportRow in
            let entry = journal(for: night)
            var sounds: [SoundKind: Int] = [:]
            for event in state.sounds where event.start >= night.windowStart && event.start < night.windowEnd { sounds[event.kind, default: 0] += 1 }
            let log = (state.wakeLogs ?? []).last { $0.latest >= night.windowStart && $0.latest < night.windowEnd }
            return NightExportRow(date: night.windowStart, appleTotalSleep: night.asleepSeconds, toFallAsleep: toFallAsleep(for: night),
                                  wakeUps: night.interruptions.count, sleepingHeartRate: sleepingHeartRate(for: night), rating: entry?.rating,
                                  tags: (entry?.tagIDs ?? []).compactMap { names[$0] }.sorted(), sounds: sounds,
                                  gentleWakeUsed: log != nil, wakeDecision: log?.tappedAt)
        }
        let phoneRows = visiblePhoneNights.map { night -> NightExportRow in
            let entry = journal(nightID: night.nightID)
            var sounds: [SoundKind: Int] = [:]
            for event in state.sounds where event.start >= night.start && event.start < (night.end ?? night.start) { sounds[event.kind, default: 0] += 1 }
            let e = night.estimate
            return NightExportRow(date: night.nightID, appleTotalSleep: e?.timeAsleep ?? 0, toFallAsleep: e?.fellAsleep.map { $0.timeIntervalSince(night.start) },
                                  wakeUps: e?.wakeUps.count ?? 0, sleepingHeartRate: nil, rating: entry?.rating,
                                  tags: (entry?.tagIDs ?? []).compactMap { names[$0] }.sorted(), sounds: sounds, gentleWakeUsed: false, wakeDecision: nil,
                                  source: "phone", inBedStart: night.start, inBedEnd: night.end, fellAsleep: e?.fellAsleep, wokeForGood: e?.wokeForGood)
        }
        return NightExportRow.csv(rows + phoneRows)
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
    /// A night started or ended on the Watch. Starting one never starts the iPhone microphone; ending one ends the
    /// matching iPhone night, including any sound it was recording. Repeated or late messages are no-ops.
    public func importWatchMarker(id: UUID, start: Date, end: Date?) async {
        let skew = Date.now.addingTimeInterval(60) // the two clocks can differ slightly
        guard !isDemo, canSave, start <= skew, end.map({ $0 >= start && $0 <= skew }) ?? true else { return }
        if let cutoff = state.ignoreWatchRecordsBefore, start < cutoff { return }
        if let i = state.sessions.firstIndex(where: { $0.id == id || $0.watchID == id }) {
            guard let end, state.sessions[i].end == nil else { return }
            await finishSession(at: i, end: end, status: "Ended on Watch")
        } else if end == nil, let i = state.sessions.lastIndex(where: { $0.end == nil }) {
            // Both devices started a night before hearing from each other: keep one night, linked to the Watch's.
            state.sessions[i].watchID = id; await persist()
        } else {
            var marker = TonightSession(start: start, requestedAudio: false, status: end == nil ? "Started on Watch · microphone off" : "Watch in-bed marker")
            marker.id = id; marker.end = end; marker.origin = .watch
            state.sessions.append(marker); await persist()
            if end == nil { onSessionChanged?(marker) }
        }
    }
    /// Time from the latest in-bed marker (iPhone or Watch) before the night's first detected sleep. An estimate, not measured latency.
    public func markerToFirstSleep(for night: SleepNight) -> TimeInterval? {
        guard let first = night.firstSleep,
              let session = state.sessions.last(where: { $0.start >= night.windowStart && $0.start < first }) else { return nil }
        return first.timeIntervalSince(session.start)
    }
    /// The Tonight session behind a night, from its start to its end (or now while it's still open).
    public func tonightSession(for night: SleepNight) -> DateInterval? {
        guard let first = night.firstSleep, let last = night.lastSleep,
              let session = state.sessions.last(where: { $0.start < last && ($0.end ?? .now) > first && ($0.end ?? .now) > $0.start }) else { return nil }
        return DateInterval(start: session.start, end: max(session.start, session.end ?? .now))
    }
    public func inBed(for night: SleepNight) -> InBedEstimate? {
        guard let session = tonightSession(for: night),
              state.sessions.contains(where: { $0.start == session.start && $0.end != nil }) else { return nil }
        return InBedEstimate(night: night, session: session)
    }
    public func watchStop(for night: SleepNight) -> WatchStop? {
        let heart = snapshot.vitals.filter { $0.kind == .heartRate }.map(\.end)
        let weekday = night.lastSleep.map { Calendar.current.component(.weekday, from: $0) }
        return NightCorrections.watchStop(night: night, heartRateTimes: heart, session: tonightSession(for: night),
                                          usualWakeMinutes: weekday.flatMap { usualWake[$0] })
    }
    public func isIncludedAnyway(_ night: SleepNight) -> Bool { state.includedIncompleteNights?.contains(night.id) == true }
    public func setIncludedAnyway(_ night: SleepNight, _ include: Bool) async {
        var included = Set(state.includedIncompleteNights ?? [])
        if include { included.insert(night.id) } else { included.remove(night.id) }
        state.includedIncompleteNights = included.sorted(); await persist()
    }
    /// Nights left out of averages: Tonight nights where the Watch stopped recording, unless included anyway.
    public var leftOutNights: Set<Date> {
        Set(nights.filter { night in watchStop(for: night)?.excludesFromAverages == true && !isIncludedAnyway(night) }.map(\.id))
    }
    /// Averages and trends never compare across a watchOS major-version change, where Apple's algorithm may differ.
    public var lastVersionBreak: Date? { NightCorrections.versionBreaks(nights).last }
    /// Nights that feed averages and trends: corrected history (Apple's data, reconciled, minus incomplete nights),
    /// limited to the current watchOS version.
    public var trendNights: [SleepNight] {
        let leftOut = leftOutNights, versionStart = lastVersionBreak ?? .distantPast
        return nights.filter { !leftOut.contains($0.id) && $0.windowStart >= versionStart }
    }
    public func deleteLocalData() async {
        await stopTonight(); audio?.stopPlayback(); playingID = nil
        captureGeneration = nil
        do {
            try await store?.deleteAll(); state = LocalState(); canSave = store != nil; phoneNights = []
            state.ignoreWatchRecordsBefore = .now
            await persist()
            snapshot = HealthSnapshot(samples: []); nights = []; showSettings = false; showOnboarding = true
            onSnapshot?(nil)
        } catch { self.error = "Deletion could not finish: \(error.localizedDescription)" }
    }
    /// Readings that overlap first-to-last sleep. Nightly summaries such as wrist temperature span the whole
    /// session and usually start before the first asleep segment, so a start-date-inside test would drop them.
    private func overnightValues(_ kind: VitalKind, _ night: SleepNight) -> [Double] {
        guard let start = night.firstSleep, let end = night.lastSleep else { return [] }
        return snapshot.vitals.filter { $0.kind == kind && $0.overlaps(start, end) }.map(\.value)
    }
    public func vital(_ kind: VitalKind, night: SleepNight) -> (value: Double, baseline: Double?, count: Int)? {
        let values = overnightValues(kind, night)
        guard let value = Insights.median(values) else { return nil }
        let priorNights = nights.filter { $0.windowStart < night.windowStart }.suffix(30)
        let nightlyValues = priorNights.compactMap { Insights.median(overnightValues(kind, $0)) }
        return (value, nightlyValues.count >= 7 ? Insights.median(nightlyValues) : nil, values.count)
    }
}
