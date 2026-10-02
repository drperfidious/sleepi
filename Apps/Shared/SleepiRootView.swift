import SwiftUI
import SleepiCore

public struct SleepiRootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    public init(model: AppModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 7) { Image(systemName: "moon.fill").font(.system(size: 15)); Text("sleepi").font(.system(size: 23, weight: .medium, design: .rounded)).tracking(-0.8) }
                    .foregroundStyle(SleepiTheme.lavender)
                Spacer()
                if model.isDemo { Text("PREVIEW").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(SleepiTheme.muted) }
                Button { model.showSettings = true } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 18)).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("Settings")
            }.padding(.horizontal, 24).padding(.top, 9).padding(.bottom, 5)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch model.selectedTab {
                    case 1: TonightView(model: model)
                    case 2: SoundsView(model: model)
                    case 3: TrendsView(model: model)
                    default: LastNightView(model: model)
                    }
                }.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 30).frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
            }
            .refreshable { await model.refresh() }
            HStack(spacing: 0) {
                tab("Last night", symbol: "moon.stars", index: 0)
                tab("Tonight", symbol: "sparkle", index: 1)
                tab("Sounds", symbol: "waveform", index: 2)
                tab("Trends", symbol: "chart.xyaxis.line", index: 3)
            }.padding(.top, 14).padding(.bottom, 12).background(SleepiTheme.background)
                .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
        }
        .background(SleepiTheme.background).foregroundStyle(SleepiTheme.ink)
        .preferredColorScheme(.dark).tint(SleepiTheme.lavender)
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.refresh(); await model.pruneClips() } } }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .sheet(isPresented: $model.showStartSheet) { StartSheet(model: model) }
        .sheet(isPresented: $model.showOnboarding) { OnboardingView(model: model).interactiveDismissDisabled() }
        .alert("A little attention needed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onOpenURL { url in
            guard url.scheme == "sleepi", url.host == "tonight" else { return }
            model.selectedTab = 1; model.showStartSheet = model.state.settings.onboardingComplete && model.activeSession == nil
        }
    }
    private func tab(_ title: String, symbol: String, index: Int) -> some View {
        Button { model.selectedTab = index } label: {
            VStack(spacing: 7) { Image(systemName: symbol).font(.system(size: 18)); Text(title).font(.system(size: 10, weight: .medium)) }
                .foregroundStyle(model.selectedTab == index ? SleepiTheme.lavender : SleepiTheme.muted)
                .frame(maxWidth: .infinity).frame(minHeight: 44)
        }.buttonStyle(.plain).accessibilityAddTraits(model.selectedTab == index ? [.isSelected] : [])
    }
}

struct PageHeading: View {
    var eyebrow: String; var title: String; var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow(text: eyebrow)
            Text(title).font(.system(size: 31, weight: .regular, design: .serif))
            if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(SleepiTheme.muted).lineSpacing(4) }
        }
    }
}

struct LastNightView: View {
    @Bindable var model: AppModel
    @State private var journalOpen = false
    @State private var showRaw = false
    var body: some View {
        if let phoneNight = model.selectedPhoneNight {
            PhoneNightView(model: model, night: phoneNight)
        } else if let night = model.selectedNight {
            HStack(alignment: .top) {
                PageHeading(eyebrow: "A little more understanding", title: "Rest, in perspective.", subtitle: "")
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 12) {
                Menu {
                    ForEach(model.nights.reversed()) { n in Button(n.lastSleep?.formatted(date: .abbreviated, time: .omitted) ?? "Night") { model.selectedNightID = n.id } }
                } label: {
                    HStack(spacing: 7) { Text((night.lastSleep ?? night.windowEnd).formatted(.dateTime.weekday(.wide).month(.abbreviated).day())); Image(systemName: "chevron.down").font(.system(size: 9)) }.font(.system(size: 12)).foregroundStyle(SleepiTheme.muted)
                }.menuStyle(.borderlessButton).fixedSize()
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("\(Int(night.asleepSeconds / 3600))").font(.system(size: 72, weight: .ultraLight, design: .rounded)).tracking(-4)
                    Text("h").font(.system(size: 24, weight: .light)).foregroundStyle(SleepiTheme.muted)
                    Text("\(Int(night.asleepSeconds / 60) % 60)").font(.system(size: 72, weight: .ultraLight, design: .rounded)).tracking(-4)
                    Text("m").font(.system(size: 24, weight: .light)).foregroundStyle(SleepiTheme.muted)
                    Spacer()
                    Image(systemName: "moon.zzz").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(SleepiTheme.lavender.opacity(0.8)).accessibilityHidden(true)
                }.accessibilityElement(children: .ignore).accessibilityLabel("\(DurationText.hoursMinutes(night.asleepSeconds)) asleep")
                HStack(spacing: 6) { Circle().fill(SleepiTheme.mint).frame(width: 5, height: 5); Text("Asleep · estimated by Apple Watch").font(.system(size: 12)).foregroundStyle(SleepiTheme.muted) }
            }
            MorningCard(model: model, nightID: night.id)
            Card {
                HStack { Eyebrow(text: "The shape of your night"); Spacer(); Image(systemName: "applewatch").foregroundStyle(SleepiTheme.muted) }
                NightChart(night: night)
                HStack(spacing: 0) {
                    ForEach([SleepStage.rem, .core, .deep], id: \.self) { stage in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 5) { Circle().fill(SleepiTheme.color(stage)).frame(width: 5); Text(stage.title).foregroundStyle(SleepiTheme.muted) }.font(.system(size: 11))
                            Text(DurationText.hoursMinutes(night.seconds(in: stage))).font(.system(size: 14, weight: .medium)).monospacedDigit()
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("Apple’s own testing says its most common mistake is calling deep sleep core sleep. Trust the trend over any one night.").font(.caption).foregroundStyle(SleepiTheme.muted)
                if night.overlapSeconds > 0 { Text("Apple Watch wrote overlapping records for \(DurationText.hoursMinutes(night.overlapSeconds)). Each minute is counted once\(night.conflictingSeconds > 0 ? "; \(DurationText.hoursMinutes(night.conflictingSeconds)) where they disagreed is shown as Asleep or left unknown" : "").").font(.caption).foregroundStyle(SleepiTheme.muted) }
                Button { showRaw = true } label: { HStack { Text("Explore the timeline"); Spacer(); Image(systemName: "arrow.up.right") }.font(.system(size: 11)).foregroundStyle(SleepiTheme.lavender) }.buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 12) {
                miniMetric("First sleep", value: night.firstSleep?.formatted(date: .omitted, time: .shortened) ?? "—", symbol: "moon")
                miniMetric("Last sleep", value: night.lastSleep?.formatted(date: .omitted, time: .shortened) ?? "—", symbol: "sun.horizon")
            }
            if let stop = model.watchStop(for: night) {
                Card {
                    Eyebrow(text: stop.excludesFromAverages ? "Incomplete night" : "Possible gap")
                    if stop.excludesFromAverages {
                        Text("Watch stopped recording at \(stop.at.formatted(date: .omitted, time: .shortened)).").font(.subheadline)
                        Text("Sleep and heart-rate records ended together while your night was still open, so this night is left out of averages and trends.").font(.caption).foregroundStyle(SleepiTheme.muted)
                        Toggle("Include anyway", isOn: Binding(get: { model.isIncludedAnyway(night) }, set: { value in Task { await model.setIncludedAnyway(night, value) } })).font(.caption)
                    } else {
                        Text("Watch data stops at \(stop.at.formatted(date: .omitted, time: .shortened)), sleep and heart rate together, well before your usual wake-up. If you were still in bed, this night is incomplete. It still counts, because an early wake looks the same.").font(.caption).foregroundStyle(SleepiTheme.muted)
                    }
                }
            }
            if let bed = model.inBed(for: night) {
                Card {
                    Eyebrow(text: "In bed · estimates from Tonight")
                    DetailLine(title: "Time in bed", value: DurationText.hoursMinutes(bed.timeInBed))
                    DetailLine(title: "Time to fall asleep", value: DurationText.hoursMinutes(bed.toFallAsleep))
                    DetailLine(title: "Sleep efficiency", value: "\(Int((bed.efficiency * 100).rounded()))%")
                    Text("From your Tonight start and end to Apple’s sleep. Apple counts some still-awake time as sleep, so these lean optimistic.").font(.caption).foregroundStyle(SleepiTheme.muted)
                }
            } else if let latency = model.markerToFirstSleep(for: night) {
                Text("First detected sleep came \(DurationText.hoursMinutes(latency)) after your in-bed marker. An estimate, not measured sleep latency.")
                    .font(.caption).foregroundStyle(SleepiTheme.muted)
            }
            HStack(alignment: .top, spacing: 12) {
                let woke = night.interruptions
                miniMetric("Awake in the night", value: woke.count == 0 ? "None recorded" : "\(woke.count)× · \(Int(woke.seconds / 60))m", symbol: "eye")
                let heard = model.selectedSounds.filter { !$0.notMe }
                miniMetric("Sounds kept", value: heard.isEmpty ? "—" : "\(heard.count) · \(heard.filter { $0.kind == .snoring }.count) snoring", symbol: "waveform")
            }
            Card {
                HStack { Eyebrow(text: "Overnight, quietly"); Spacer(); Text("APPLE HEALTH").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(SleepiTheme.muted) }
                ForEach([VitalKind.heartRate, .hrv, .respiratoryRate, .oxygen, .wristTemperature], id: \.self) { kind in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(kind.title).font(.system(size: 13))
                            if let metric = model.vital(kind, night: night), let baseline = metric.baseline {
                                Text("Typical median \(baseline.formatted(.number.precision(.fractionLength(1)))) \(kind.unit)").font(.system(size: 10)).foregroundStyle(SleepiTheme.muted)
                            }
                        }
                        Spacer()
                        if let metric = model.vital(kind, night: night) {
                            Text("\(metric.value.formatted(.number.precision(.fractionLength(kind == .heartRate || kind == .hrv ? 0 : 1)))) \(kind.unit)").font(.system(size: 14)).monospacedDigit().foregroundStyle(SleepiTheme.mint)
                        } else { Text("Unavailable").font(.caption).foregroundStyle(SleepiTheme.muted) }
                    }
                }
                Text("Medians of readings between first and last detected sleep. Temperature is absolute. Baselines use 7–30 prior nights, not Apple’s Vitals range.").font(.system(size: 10)).foregroundStyle(SleepiTheme.muted).lineSpacing(3)
            }
            Button { journalOpen = true } label: {
                Card {
                    HStack { Image(systemName: "square.and.pencil").foregroundStyle(SleepiTheme.lavender); VStack(alignment: .leading, spacing: 4) { Text("A note to your morning").font(.system(size: 14)); Text("How did the night feel?").font(.system(size: 12)).foregroundStyle(SleepiTheme.muted) }; Spacer(); Image(systemName: "plus").foregroundStyle(SleepiTheme.lavender) }
                }
            }.buttonStyle(.plain)
            Text(model.healthStatus).font(.system(size: 10)).foregroundStyle(SleepiTheme.muted).frame(maxWidth: .infinity)
                .sheet(isPresented: $journalOpen) { JournalSheet(model: model, night: night) }
                .sheet(isPresented: $showRaw) { RawNightView(night: night, model: model) }
        } else {
            PageHeading(eyebrow: "Good rest starts here", title: "Your night, made clear.", subtitle: model.watchAvailable ? "Apple does the sensing. sleepi helps you find the patterns." : "")
            EmptyCard(symbol: "moon.stars", title: "Room for your first night", detail: model.watchAvailable ? model.healthStatus : "Start a night from Tonight and keep your phone nearby. sleepi will estimate when you fell asleep, when you woke up, and what it heard. With an Apple Watch, sleepi also shows Apple’s sleep stages.")
            PrimaryButton(title: model.isLoading ? "Reading Apple Health…" : "Connect Apple Health", symbol: "heart") { Task { await model.connect() } }.disabled(model.isLoading)
            Card { Eyebrow(text: "Always yours"); Text("Your stages stay Apple’s. Your alarm stays yours.").font(.title3); Text("sleepi reads your sleep data and keeps your notes on this device. It cannot change your rings, sleep records, or Clock alarm.").font(.subheadline).foregroundStyle(SleepiTheme.muted).lineSpacing(5) }
        }
    }
    private func miniMetric(_ title: String, value: String, symbol: String) -> some View {
        Card { HStack { Image(systemName: symbol); Text(title) }.font(.system(size: 11)).foregroundStyle(SleepiTheme.muted); Text(value).font(.system(size: 20, weight: .light)).monospacedDigit() }
    }
}

struct NightChart: View {
    let night: SleepNight
    @State private var selected: StageSegment?
    private let rows: [SleepStage] = [.awake, .rem, .core, .deep]
    private func row(_ stage: SleepStage) -> Int { rows.firstIndex(of: stage) ?? 2 }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) { ForEach(rows, id: \.self) { stage in Text(stage.title).font(.system(size: 9)).foregroundStyle(SleepiTheme.muted).frame(height: 30) } }.frame(width: 33, alignment: .leading)
                GeometryReader { geo in
                    let start = night.segments.first?.start ?? night.windowStart
                    let end = night.segments.last?.end ?? night.windowEnd
                    let duration = max(1, end.timeIntervalSince(start))
                    ZStack(alignment: .topLeading) {
                        ForEach(0..<4) { i in RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.025)).frame(height: 25).offset(y: CGFloat(i) * 30 + 2.5) }
                        ForEach(night.segments) { segment in
                            let x = segment.start.timeIntervalSince(start) / duration * geo.size.width
                            let width = max(2, segment.seconds / duration * geo.size.width)
                            Button { selected = segment } label: {
                                RoundedRectangle(cornerRadius: 3).fill(SleepiTheme.color(segment.stage)).frame(width: width, height: 22)
                            }.buttonStyle(.plain).offset(x: x, y: CGFloat(row(segment.stage)) * 30 + 4)
                                .accessibilityLabel("\(segment.stage.title), \(segment.start.formatted(date: .omitted, time: .shortened)), \(Int(segment.seconds / 60)) minutes")
                        }
                    }
                }.frame(height: 120)
            }
            HStack { Text(night.segments.first?.start.formatted(date: .omitted, time: .shortened) ?? ""); Spacer(); Text(night.segments.last?.end.formatted(date: .omitted, time: .shortened) ?? "") }.font(.system(size: 9)).foregroundStyle(SleepiTheme.muted).padding(.leading, 41)
            if let selected { Text("\(selected.stage.title) · \(selected.start.formatted(date: .omitted, time: .shortened)) · \(Int(selected.seconds / 60)) min").font(.caption).foregroundStyle(SleepiTheme.lavender) }
        }.accessibilityElement(children: .contain)
    }
}

struct RawNightView: View {
    let night: SleepNight
    let model: AppModel
    var body: some View {
        SheetFrame(title: "Your timeline") {
            Text("Apple Watch’s estimated stages. Gaps are unknown. sleepi does not replace or correct these records.").font(.subheadline).foregroundStyle(SleepiTheme.muted)
            DetailLine(title: "Recorded awake", value: DurationText.hoursMinutes(night.awakeSeconds))
            DetailLine(title: "Apple’s raw record", value: "\(DurationText.hoursMinutes(night.rawAsleepSeconds)) asleep as written")
            if night.overlapSeconds > 0 { DetailLine(title: "Overlapping records merged", value: DurationText.hoursMinutes(night.overlapSeconds)) }
            if let major = night.osMajor { DetailLine(title: "Recorded with", value: "watchOS \(major)") }
            ForEach(model.state.sounds.filter { $0.start >= night.windowStart && $0.start < night.windowEnd }.sorted { $0.start < $1.start }) { event in
                DetailLine(title: "\(event.start.formatted(date: .omitted, time: .shortened)) · \(event.kind.title)", value: event.notMe ? "Not me" : "Sound")
            }
            DetailLine(title: "Watch sources", value: "\(night.sourceCount)")
            ForEach(VitalKind.allCases, id: \.self) { kind in
                if let metric = model.vital(kind, night: night) {
                    DetailLine(title: kind.title, value: "\(metric.value.formatted(.number.precision(.fractionLength(1)))) \(kind.unit) · \(metric.count) readings")
                }
            }
            if let latency = model.markerToFirstSleep(for: night) {
                DetailLine(title: "Marker to first detected sleep", value: DurationText.hoursMinutes(latency))
                Text("An estimate from your in-bed marker; this is not measured sleep latency.").font(.caption).foregroundStyle(SleepiTheme.muted)
            }
            ForEach(night.segments) { s in DetailLine(title: "\(s.start.formatted(date: .omitted, time: .shortened)) · \(s.stage.title)", value: "\(Int(s.seconds / 60)) min") }
        }
    }
}

/// Optional morning sleep diary: a rating and chips for the evening before. Each tap saves; skipping is fine.
struct MorningCard: View {
    @Bindable var model: AppModel
    let nightID: Date
    var body: some View {
        let entry = model.journal(nightID: nightID)
        Card {
            Eyebrow(text: "How did you sleep?")
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { value in
                    Button { Task { await model.setRating(entry?.rating == value ? nil : value, nightID: nightID) } } label: {
                        Text(JournalTag.ratingTitles[value - 1]).font(.system(size: 11)).multilineTextAlignment(.center).lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(entry?.rating == value ? SleepiTheme.lavender.opacity(0.25) : SleepiTheme.card, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityAddTraits(entry?.rating == value ? [.isSelected] : [])
                }
            }
            Text("The evening before").font(.caption).foregroundStyle(SleepiTheme.muted)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(model.visibleTags) { tag in
                    let on = entry?.tagIDs.contains(tag.id) == true
                    Button { Task { await model.toggleTag(tag, nightID: nightID) } } label: {
                        Text(tag.name).font(.caption).lineLimit(2).frame(maxWidth: .infinity, minHeight: 34)
                            .background(on ? SleepiTheme.lavender.opacity(0.25) : SleepiTheme.card, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }
            Text("Optional, and kept on this iPhone only, never in Health. Add or rename chips in Settings.").font(.system(size: 10)).foregroundStyle(SleepiTheme.muted)
        }
    }
}

/// Last Night for a night recorded by the iPhone alone. Measured items are labelled measured; everything else is an estimate.
struct PhoneNightView: View {
    @Bindable var model: AppModel
    let night: PhoneNight
    private func t(_ d: Date?) -> String { d?.formatted(date: .omitted, time: .shortened) ?? "—" }
    var body: some View {
        let e = night.estimate
        PageHeading(eyebrow: "Phone night · estimate", title: "Rest, in perspective.", subtitle: "")
        if model.visiblePhoneNights.count > 1 {
            Menu {
                ForEach(model.visiblePhoneNights.reversed()) { n in Button(n.start.formatted(date: .abbreviated, time: .omitted)) { model.selectedNightID = n.nightID } }
            } label: {
                HStack(spacing: 7) { Text(night.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())); Image(systemName: "chevron.down").font(.system(size: 9)) }.font(.system(size: 12)).foregroundStyle(SleepiTheme.muted)
            }.menuStyle(.borderlessButton).fixedSize()
        }
        if let last = model.visiblePhoneNights.last, last.end.map({ Date.now.timeIntervalSince($0) > 30 * 3600 }) == true {
            Text("No night recorded since then. Tap Start Tonight before bed.").font(.caption).foregroundStyle(SleepiTheme.muted)
        }
        Card {
            DetailLine(title: "In bed (measured)", value: "\(t(night.start))–\(t(night.end))")
            DetailLine(title: "Fell asleep around (estimate)", value: e?.fellAsleep.map { t($0) } ?? "Couldn’t tell")
            DetailLine(title: "Woke for good around (estimate)", value: e?.wokeForGood.map { t($0) } ?? "Couldn’t tell")
            DetailLine(title: "Time asleep (estimate)", value: e?.timeAsleep.map { "about " + DurationText.hoursMinutes($0) } ?? "Couldn’t tell")
            if let e, e.noDataSeconds > 0 { Text("No data for \(DurationText.hoursMinutes(e.noDataSeconds)) (listening paused). That time isn’t counted as sleep.").font(.caption).foregroundStyle(SleepiTheme.muted) }
        }
        PhoneNightTimeline(night: night, sounds: model.state.sounds.filter { $0.start >= night.start && $0.start < (night.end ?? night.start) })
        if let wakeUps = e?.wakeUps, !wakeUps.isEmpty {
            Card {
                Eyebrow(text: "Wake-ups")
                ForEach(wakeUps, id: \.start) { w in
                    Text(w.kind == .phoneUse ? "Used phone \(t(w.start))–\(t(w.end))" : "Restless \(t(w.start))–\(t(w.end)), maybe awake").font(.subheadline)
                }
            }
        }
        MorningCard(model: model, nightID: night.nightID)
        Text("From your iPhone’s microphone and motion. Phones can tell quiet from restless, not light, deep or REM sleep. An Apple Watch measures sleep stages.").font(.caption).foregroundStyle(SleepiTheme.muted).lineSpacing(3)
    }
}

/// In-bed band, quiet stretches shaded, phone use and restless marks on top, sound highlights as dots.
struct PhoneNightTimeline: View {
    let night: PhoneNight
    let sounds: [SoundEvent]
    var body: some View {
        let end = night.end ?? night.start.addingTimeInterval(1)
        let total = max(1, end.timeIntervalSince(night.start))
        GeometryReader { geo in
            let w = geo.size.width
            let x: (Date) -> CGFloat = { d in CGFloat(d.timeIntervalSince(night.start) / total) * w }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(SleepiTheme.card).frame(height: 34).offset(y: 10)
                if let e = night.estimate, let f = e.fellAsleep, let k = e.wokeForGood {
                    RoundedRectangle(cornerRadius: 4).fill(SleepiTheme.lavender.opacity(0.35)).frame(width: max(2, x(k) - x(f)), height: 34).offset(x: x(f), y: 10)
                    ForEach(e.wakeUps, id: \.start) { wake in
                        Rectangle().fill(wake.kind == .phoneUse ? SleepiTheme.ink.opacity(0.8) : SleepiTheme.mint.opacity(0.8))
                            .frame(width: max(2, x(wake.end) - x(wake.start)), height: 34).offset(x: x(wake.start), y: 10)
                    }
                }
                ForEach(sounds) { s in Circle().fill(SleepiTheme.mint).frame(width: 6, height: 6).offset(x: x(s.start) - 3, y: 0) }
            }
        }
        .frame(height: 48)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Night timeline: quiet stretches shaded, wake-ups marked, \(sounds.count) sound highlights")
    }
}
