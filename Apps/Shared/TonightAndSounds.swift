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
                Text("Elapsed time is time since your marker, not time asleep. Ending here ends it on your Watch too.").font(.caption).foregroundStyle(SleepiTheme.muted)
                PrimaryButton(title: model.isStopping ? "Ending…" : "End tonight", symbol: "stop") { Task { await model.stopTonight() } }.disabled(model.isStopping)
            }
        } else {
            PrimaryButton(title: "Settle in", symbol: "moon") { model.showStartSheet = true }
            Text("Apple Watch will track your sleep either way.").font(.system(size: 12)).foregroundStyle(SleepiTheme.muted).frame(maxWidth: .infinity)
        }
        Card {
            Eyebrow(text: "Before you drift off")
            checklist("Wear your Watch, with enough charge.", symbol: "applewatch")
            checklist("Keep your usual Sleep Focus and alarm.", symbol: "alarm")
            checklist("For sound, start here on your iPhone.", symbol: "mic")
        }
    }
    private func checklist(_ text: String, symbol: String) -> some View { HStack(spacing: 12) { Image(systemName: symbol).frame(width: 20).foregroundStyle(SleepiTheme.lavender); Text(text).font(.system(size: 13)).foregroundStyle(SleepiTheme.muted) } }
}

struct StartSheet: View {
    @Bindable var model: AppModel
    @State private var sound = false
    var body: some View {
        SheetFrame(title: "Make room for rest") {
            Text("Save an in-bed marker. Apple Watch continues its own sleep tracking.").foregroundStyle(SleepiTheme.muted)
            Card {
                Toggle(isOn: $sound) { Label("Record sound highlights", systemImage: "waveform") }.disabled(!model.audioAvailable)
                Text(model.isDemo ? "Sound recording is available in the iPhone app. This preview doesn’t use your microphone." : "Your microphone listens on this iPhone. Short clips may include people nearby. They stay on this device and are removed after 14 days at the next cleanup, unless saved. Sounds from other apps keep playing, and sleepi may hear them.").font(.caption).foregroundStyle(SleepiTheme.muted).lineSpacing(4)
            }
            Card {
                Label("Gentle wake · on Apple Watch", systemImage: "applewatch").font(.subheadline)
                Text("An experiment you switch on when you start the night on your Watch: a wrist tap, no sound, in the 25 minutes before the time you pick. Keep Apple’s alarm set; it stays the real alarm.").font(.caption).foregroundStyle(SleepiTheme.muted).lineSpacing(4)
            }
            PrimaryButton(title: model.isStarting ? "Starting…" : sound ? "Start with microphone" : "Save my in-bed time", symbol: sound ? "mic" : "moon") { Task { await model.startTonight(sound: sound) } }.disabled(model.isStarting)
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
