import SwiftUI
import SleepiCore

struct TonightView: View {
    @Bindable var model: AppModel
    var body: some View {
        PageHeading(eyebrow: "Leave the day here", title: "A softer goodnight.", subtitle: "An optional layer for a little more context.")
        ZStack {
            Circle().stroke(SleepiTheme.lavender.opacity(0.06), lineWidth: 1).frame(width: 224, height: 224)
            Circle().stroke(SleepiTheme.lavender.opacity(0.1), lineWidth: 1).frame(width: 182, height: 182)
            Circle().fill(RadialGradient(colors: [SleepiTheme.lavender.opacity(0.12), .clear], center: .center, startRadius: 5, endRadius: 90)).frame(width: 180, height: 180)
            Image(systemName: model.activeSession == nil ? "moon.stars" : "moon.zzz").font(.system(size: 62, weight: .ultraLight)).foregroundStyle(SleepiTheme.lavender)
        }.frame(maxWidth: .infinity).padding(.vertical, 15).accessibilityHidden(true)
        if let session = model.activeSession {
            Card {
                Eyebrow(text: "Your night has begun")
                Text(session.start, style: .timer).font(.system(size: 44, weight: .ultraLight, design: .rounded)).monospacedDigit()
                Text(session.requestedAudio ? model.recordingStatus : session.origin == .watch ? "Started on Apple Watch · microphone off" : "In-bed marker saved · microphone off").foregroundStyle(SleepiTheme.mint).font(.subheadline)
                if !session.requestedAudio, model.audioAvailable {
                    Button { Task { await model.addSoundToTonight() } } label: { Label("Add sound recording", systemImage: "mic") }.font(.subheadline).disabled(model.isStarting)
                }
                Text(model.watchAvailable ? "Elapsed time is time since your marker, not time asleep. Ending here ends it on your Watch too." : "Elapsed time is time since your marker, not time asleep.").font(.caption).foregroundStyle(SleepiTheme.muted)
                PrimaryButton(title: model.isStopping ? "Ending…" : "End tonight", symbol: "stop") { Task { await model.stopTonight() } }.disabled(model.isStopping)
            }
        } else {
            PrimaryButton(title: "Settle in", symbol: "moon") { model.showStartSheet = true }
            Text(model.watchAvailable ? "Apple Watch will track your sleep either way." : "Saves your in-bed time; sound highlights are optional.").font(.system(size: 12)).foregroundStyle(SleepiTheme.muted).frame(maxWidth: .infinity)
        }
        Card {
            Eyebrow(text: "Before you drift off")
            if model.watchAvailable { checklist("Wear your Watch, with enough charge.", symbol: "applewatch") }
            checklist("Keep your usual Sleep Focus and alarm.", symbol: "alarm")
            checklist("For sound, start here on your iPhone.", symbol: "mic")
        }
    }
    private func checklist(_ text: String, symbol: String) -> some View { HStack(spacing: 12) { Image(systemName: symbol).frame(width: 20).foregroundStyle(SleepiTheme.lavender); Text(text).font(.system(size: 13)).foregroundStyle(SleepiTheme.muted) } }
}

struct StartSheet: View {
    @Bindable var model: AppModel
    @State private var sound = false
    @State private var gentle = false
    @State private var wake = Date.now
    /// Phone-only tracking: always offered without a Watch; with one, for a night the Watch stays on its charger.
    @State private var phoneOnly = false
    @State private var trackSleep = true
    private var phoneMode: Bool { !model.isDemo && (!model.watchAvailable || phoneOnly) }
    /// The hidden test switch also listens on Watch nights started here, for the comparison log.
    private var alongside: Bool { model.watchAvailable && !phoneOnly && model.state.settings.phoneTrackingAlongsideWatch == true }
    var body: some View {
        SheetFrame(title: "Make room for rest") {
            Text(phoneMode ? "Your iPhone listens through the night to estimate when you fell asleep and woke up. Nothing is recorded unless you save highlights." : "Save an in-bed marker. Apple Watch continues its own sleep tracking.").foregroundStyle(SleepiTheme.muted)
            if model.watchAvailable && !model.isDemo {
                Toggle(isOn: $phoneOnly) { Label("Phone only tonight", systemImage: "iphone") }
                    .font(.subheadline)
            }
            if phoneMode || alongside {
                Card {
                    Toggle(isOn: $trackSleep) { Label(alongside ? "Phone tracking (test)" : "Track my sleep", systemImage: "waveform.path") }
                    Text(trackSleep ? "Keep your phone on the bed stand, plugged in, out of the fan’s airflow." : "Only your in-bed time is saved tonight.").font(.caption).foregroundStyle(SleepiTheme.muted).lineSpacing(4)
                }
            }
            Card {
                Toggle(isOn: $sound) { Label(phoneMode ? "Save sound highlights" : "Record sound highlights", systemImage: "waveform") }.disabled(!model.audioAvailable)
                Text(model.isDemo ? "Sound recording is available in the iPhone app. This preview doesn’t use your microphone." : "Short clips of snoring, talking or coughing may include people nearby. They stay on this device and are removed after 14 days at the next cleanup, unless saved. Sounds from other apps keep playing, and sleepi may hear them.").font(.caption).foregroundStyle(SleepiTheme.muted).lineSpacing(4)
            }
            if model.watchAvailable && !model.isDemo && !phoneOnly {
                Card {
                    Toggle(isOn: $gentle) { Label("Gentle wake on Apple Watch", systemImage: "applewatch") }
                        .onAppear { wake = model.suggestedGentleWake ?? Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 7), matchingPolicy: .nextTime) ?? .now }
                    if gentle {
                        DatePicker("Wake by", selection: $wake, displayedComponents: .hourAndMinute)
                        Text("\(model.gentleWake.windowMinutes)-min window · \(model.gentleWake.sensitivity.title) (change in Settings). Then open sleepi on your Watch and tap Set gentle wake: Apple only lets the Watch app itself schedule its wake-up. Your Clock alarm stays the real alarm.").font(.caption).foregroundStyle(SleepiTheme.muted).lineSpacing(4)
                    }
                }
            }
            let tracking = (phoneMode || alongside) && trackSleep
            PrimaryButton(title: model.isStarting ? "Starting…" : tracking ? "Start tracking" : sound ? "Start with microphone" : "Save my in-bed time", symbol: tracking || sound ? "mic" : "moon") {
                let components = Calendar.current.dateComponents([.hour, .minute], from: wake)
                let wakeAt = gentle && !phoneOnly ? Calendar.current.nextDate(after: .now, matching: components, matchingPolicy: .nextTime) : nil
                Task { await model.startTonight(sound: sound, gentleWake: wakeAt, phoneTracking: tracking, phoneOnly: phoneMode) }
            }.disabled(model.isStarting)
        }
    }
}

struct SoundsView: View {
    @Bindable var model: AppModel
    @State private var filter: SoundKind?
    @State private var deleteEvent: SoundEvent?
    var filtered: [SoundEvent] { model.state.sounds.filter { filter == nil || $0.kind == filter }.sorted { $0.start > $1.start } }
    var body: some View {
        PageHeading(eyebrow: "The things you slept through", title: "A quieter kind of replay.", subtitle: "Short moments, kept on your iPhone.")
        HStack { Text("\(Double(model.usedBytes) / 1_000_000, specifier: "%.1f") MB of 300 MB"); Spacer(); Image(systemName: "lock.shield") }.font(.caption).foregroundStyle(SleepiTheme.muted)
        if let last = model.state.sessions.last(where: { $0.soundStats != nil }), let heard = last.soundStats {
            Card {
                Eyebrow(text: "Last listening · \(last.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                Text("Listened \(DurationText.hoursMinutes(heard.listenedSeconds)) · \(heard.saved) highlight\(heard.saved == 1 ? "" : "s") saved").font(.subheadline)
                if let level = heard.roomLevelDBFS { DetailLine(title: "Typical room level", value: "\(Int(level)) dBFS") }
                ForEach([SoundKind.snoring, .speech, .coughing], id: \.self) { kind in
                    DetailLine(title: "Closest \(kind == .snoring ? "snoring" : kind.title.lowercased())", value: "\(Int(((heard.best[kind.rawValue] ?? 0) * 100).rounded()))% · saves at \(Int(SoundThresholds.confidence(for: kind) * 100))%")
                }
                Text(heard.nearMisses == 0 && heard.saved == 0 ? "Nothing came close, so it was most likely a quiet night." : "\(heard.nearMisses) near miss\(heard.nearMisses == 1 ? "" : "es"): sounds the classifier wasn't sure enough about. A steady fan lowers its certainty.").font(.caption).foregroundStyle(SleepiTheme.muted)
            }
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterPill("All", kind: nil)
                ForEach(SoundKind.allCases, id: \.self) { kind in filterPill(kind == .snoring ? "Snoring" : kind.title, kind: kind) }
            }
        }
        if filtered.isEmpty {
            EmptyCard(symbol: "waveform", title: "Nothing to replay. Yet.", detail: "Start a Tonight session with sound on to keep brief highlights. Labels are estimates of room sounds, not proof of who made them.")
            PrimaryButton(title: "Go to Tonight", symbol: "moon") { model.selectedTab = 1 }
        } else {
            ForEach(filtered) { event in
                Card {
                    HStack {
                        Image(systemName: event.kind.symbol).foregroundStyle(SleepiTheme.lavender)
                        VStack(alignment: .leading, spacing: 4) { Text(event.kind.title).font(.subheadline); Text(event.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(SleepiTheme.muted) }
                        Spacer()
                        Button { Task { await model.play(event) } } label: { Image(systemName: model.playingID == event.id ? "stop.circle" : "play.circle").font(.title) }.disabled(event.fileName == nil || model.activeSession != nil).buttonStyle(.plain).accessibilityLabel("Play or stop clip")
                    }
                    HStack {
                        Text("\(Int(event.end.timeIntervalSince(event.start)))s · \(Int(event.levelDBFS)) dBFS").font(.caption).foregroundStyle(SleepiTheme.muted)
                        Spacer()
                        Button { Task { await model.toggleStar(event) } } label: { Image(systemName: event.starred ? "star.fill" : "star") }.disabled(event.fileName == nil).accessibilityLabel(event.starred ? "Unsave clip" : "Keep clip")
                        Button(event.notMe ? "Marked not me" : "Not me") { Task { await model.toggleNotMe(event) } }.font(.caption)
                        Button { deleteEvent = event } label: { Image(systemName: "trash") }.accessibilityLabel("Delete clip")
                    }.buttonStyle(.plain)
                    if event.fileName == nil { Text("Audio expired · event summary retained").font(.caption).foregroundStyle(SleepiTheme.muted) }
                }
            }
        }
        Text("dBFS measures microphone signal level, not calibrated room loudness. “Not me” labels a clip for your review; it does not identify a speaker or train a model.").font(.caption).foregroundStyle(SleepiTheme.muted).lineSpacing(4)
            .confirmationDialog("Delete this recording?", isPresented: Binding(get: { deleteEvent != nil }, set: { if !$0 { deleteEvent = nil } })) {
                Button("Delete recording", role: .destructive) { if let event = deleteEvent { Task { await model.removeClip(event) } }; deleteEvent = nil }
            }
    }
    private func filterPill(_ text: String, kind: SoundKind?) -> some View {
        Button { filter = kind } label: { Text(text).font(.system(size: 12)).padding(.horizontal, 15).padding(.vertical, 10).background(filter == kind ? SleepiTheme.lavender.opacity(0.15) : SleepiTheme.card, in: Capsule()).foregroundStyle(filter == kind ? SleepiTheme.lavender : SleepiTheme.muted) }.buttonStyle(.plain)
    }
}
