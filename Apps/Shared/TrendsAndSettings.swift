import SwiftUI
import Charts
import SleepiCore

struct TrendsView: View {
    @Bindable var model: AppModel
    @State private var days = 30
    private var cutoff: Date { Calendar.current.date(byAdding: .day, value: -days, to: .now)! }
    /// Corrected history: Apple's nights, reconciled, minus nights the Watch stopped recording, on the current watchOS.
    private var nights: [SleepNight] { model.trendNights.filter { $0.windowEnd >= cutoff } }
    /// The chart also shows nights before a watchOS change, with a break line, but averages never cross it.
    private var chartNights: [SleepNight] { model.nights.filter { $0.windowEnd >= cutoff && !model.leftOutNights.contains($0.id) } }
    private var corrected: CorrectedSummary? {
        let start = max(cutoff, model.lastVersionBreak ?? .distantPast)
        return CorrectedSummary(nights: model.nights.filter { $0.windowEnd >= start }, leftOut: model.leftOutNights)
    }
    private func dates(_ ids: [Date]) -> String {
        ids.map { $0.addingTimeInterval(86400).formatted(.dateTime.month(.abbreviated).day()) }.joined(separator: ", ")
    }
    var body: some View {
        PageHeading(eyebrow: "Look at the longer story", title: "Patterns, without pressure.", subtitle: "One night is a moment. A few weeks tell you more.")
        Picker("Time range", selection: $days) { Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90) }.pickerStyle(.segmented)
        if model.showsPhoneNights {
            PhoneTrends(model: model, nights: model.visiblePhoneNights.filter { ($0.end ?? $0.start) >= cutoff })
        } else if nights.isEmpty {
            EmptyCard(symbol: "chart.xyaxis.line", title: "Patterns take a little time", detail: model.watchAvailable ? "Once Apple Watch has recorded your nights, you’ll see duration and schedule variation here. Missing nights stay missing." : "Once sleep is recorded, you’ll see duration and schedule variation here. Missing nights stay missing.")
        } else {
            Card {
                Eyebrow(text: "Time asleep")
                Text(DurationText.hoursMinutes(nights.reduce(0) { $0 + $1.asleepSeconds } / Double(nights.count))).font(.system(size: 34, weight: .light, design: .rounded))
                Text("Average across \(nights.count) recorded nights").font(.caption).foregroundStyle(SleepiTheme.muted)
                Chart {
                    ForEach(chartNights) { n in
                        BarMark(x: .value("Night", n.lastSleep ?? n.windowEnd, unit: .day), y: .value("Hours", n.asleepSeconds / 3600)).foregroundStyle(SleepiTheme.lavender.gradient).cornerRadius(3)
                    }
                    if let versionBreak = model.lastVersionBreak, versionBreak > cutoff {
                        RuleMark(x: .value("watchOS change", versionBreak.addingTimeInterval(86400), unit: .day)).foregroundStyle(SleepiTheme.muted).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    }
                    RuleMark(y: .value("Target", model.state.settings.targetHours)).foregroundStyle(SleepiTheme.muted.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                }.chartYScale(domain: 0...max(10, (chartNights.map { $0.asleepSeconds / 3600 }.max() ?? 0) + 1)).chartYAxis { AxisMarks(position: .leading) }.frame(height: 170)
                    .accessibilityLabel("Sleep duration chart for \(nights.count) recorded nights")
                Text("Dashed line: your \(model.state.settings.targetHours.formatted())h target. No data is filled into missing nights.").font(.caption).foregroundStyle(SleepiTheme.muted)
                if !model.visiblePhoneNights.isEmpty {
                    Text("\(model.visiblePhoneNights.count) phone night\(model.visiblePhoneNights.count == 1 ? "" : "s") left out: phone estimates and Apple Watch sleep aren’t mixed in one chart.").font(.caption).foregroundStyle(SleepiTheme.muted)
                }
                if let c = corrected {
                    let parts = [c.leftOut.isEmpty ? nil : "\(c.leftOut.count) night\(c.leftOut.count == 1 ? "" : "s") the Watch stopped recording left out (\(dates(c.leftOut)))",
                                 c.merged.isEmpty ? nil : "\(c.merged.count) night\(c.merged.count == 1 ? "" : "s") with overlapping records merged (\(dates(c.merged)))"].compactMap { $0 }
                    Text("vs Apple: \(DurationText.hoursMinutes(c.averageAsleep)) vs Apple’s raw record \(DurationText.hoursMinutes(c.appleRawAverage))\(parts.isEmpty ? ". No differences." : ": " + parts.joined(separator: "; ") + ".")")
                        .font(.caption).foregroundStyle(SleepiTheme.muted)
                }
                if let versionBreak = model.lastVersionBreak, versionBreak > cutoff {
                    Text("watchOS changed on \(versionBreak.addingTimeInterval(86400).formatted(.dateTime.month(.abbreviated).day())), which can change Apple’s sleep staging. Averages use nights since then.").font(.caption).foregroundStyle(SleepiTheme.muted)
                }
            }
            Card {
                Eyebrow(text: "A rhythm of your own")
                if let consistency = Insights.consistency(nights: nights) {
                    Text("±\(Int(consistency.wakeSpreadMinutes)) min").font(.system(size: 34, weight: .light, design: .rounded))
                    Text("Wake-time variation").font(.subheadline)
                    DetailLine(title: "Bedtime variation", value: "±\(Int(consistency.bedtimeSpreadMinutes)) min")
                    Text("Clock-time standard deviation over \(consistency.nights) recorded nights. This is schedule consistency, not the Sleep Regularity Index.").font(.caption).foregroundStyle(SleepiTheme.muted).lineSpacing(3)
                } else { Text("Seven recorded nights make a start.").font(.title3); Text("Schedule variation appears when there’s enough data. Widely scattered schedules may not have a meaningful average.").font(.caption).foregroundStyle(SleepiTheme.muted) }
            }
            Card {
                let shortfall = Insights.shortfall(nights: model.trendNights, targetHours: model.state.settings.targetHours, now: .now)
                Eyebrow(text: "Room for more rest")
                Text(DurationText.hoursMinutes(shortfall.seconds)).font(.system(size: 30, weight: .light, design: .rounded))
                Text("Below your target across \(shortfall.recordedNights) of the last 14 nights.").font(.subheadline)
                Text("Adds each recorded night’s shortfall. Longer nights don’t erase it; missing nights don’t add to it. It is not a biological measure of sleep debt.").font(.caption).foregroundStyle(SleepiTheme.muted).lineSpacing(3)
            }
            Card {
                Eyebrow(text: "Free days & scheduled days")
                if let shift = Insights.socialJetlag(nights: nights, journals: model.state.journals) { Text("\(Int(shift)) min").font(.title); Text("Difference in average mid-sleep time.").font(.subheadline) }
                else { Text("Tell us which days were free.").font(.title3); Text("Mark at least three free days and three scheduled days in your morning notes to compare mid-sleep timing. Weekends are not assumed to be free.").font(.caption).foregroundStyle(SleepiTheme.muted).lineSpacing(3) }
            }
            Card {
                Eyebrow(text: "Linked to your nights")
                ForEach(model.visibleTags) { tag in
                    switch model.tagStatuses[tag.id] {
                    case .linked(let links)?:
                        ForEach(links, id: \.measure) { link in
                            (Text("On nights after ") + Text(tag.name).italic() + Text(", \(link.measure.phrase(link.difference)) (\(link.taggedNights) nights vs \(link.untaggedNights)).")).font(.subheadline)
                        }
                    case .noClearLink(let count)?:
                        DetailLine(title: tag.name, value: "No clear link so far (\(count) nights)")
                    case .notEnough(let have)?:
                        DetailLine(title: tag.name, value: "Not enough nights yet (\(have) of \(TagLinks.minimumNights))")
                    case nil:
                        DetailLine(title: tag.name, value: "Not enough nights yet (0 of \(TagLinks.minimumNights))")
                    }
                }
                Text("One person’s sleep varies a lot from night to night, so links usually take two months or more. Weekdays are compared with weekdays and weekends with weekends. A link isn’t proof of cause.").font(.caption).foregroundStyle(SleepiTheme.muted).lineSpacing(3)
            }
        }
    }
}

struct SheetFrame<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.system(size: 24, weight: .regular, design: .serif)); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("Close") }.padding(.horizontal, 24).padding(.top, 18)
            ScrollView { VStack(alignment: .leading, spacing: 24) { content }.padding(24) }
        }.frame(minWidth: 340, minHeight: 500).background(SleepiTheme.background).foregroundStyle(SleepiTheme.ink).preferredColorScheme(.dark).tint(SleepiTheme.lavender)
    }
}

struct JournalSheet: View {
    @Bindable var model: AppModel
    var night: SleepNight
    @State private var journal: NightJournal
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, night: SleepNight) {
        self.model = model; self.night = night
        _journal = State(initialValue: model.state.journals.first { $0.nightID == night.id } ?? NightJournal(nightID: night.id))
    }
    var body: some View {
        SheetFrame(title: "A note to your morning") {
            Text((night.lastSleep ?? night.windowEnd).formatted(date: .complete, time: .omitted)).font(.caption).foregroundStyle(SleepiTheme.muted)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(model.state.tags.filter { $0.hidden != true || journal.tagIDs.contains($0.id) }) { tag in
                    Button { if journal.tagIDs.contains(tag.id) { journal.tagIDs.remove(tag.id) } else { journal.tagIDs.insert(tag.id) } } label: {
                        HStack { Text(tag.name); Spacer(); if journal.tagIDs.contains(tag.id) { Image(systemName: "checkmark") } }.font(.caption).padding(14).background(journal.tagIDs.contains(tag.id) ? SleepiTheme.lavender.opacity(0.2) : SleepiTheme.card, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityAddTraits(journal.tagIDs.contains(tag.id) ? [.isSelected] : [])
                }
            }
            Picker("Day after this night", selection: $journal.isFreeDay) { Text("Not specified").tag(Optional<Bool>.none); Text("Free day").tag(Optional(true)); Text("Scheduled day").tag(Optional(false)) }
            TextEditor(text: $journal.note).frame(minHeight: 130).scrollContentBackground(.hidden).padding(12).background(SleepiTheme.card, in: RoundedRectangle(cornerRadius: 16)).accessibilityLabel("Morning note")
            Text("Notes can be personal health information. Everything here stays on this device.").font(.caption).foregroundStyle(SleepiTheme.muted)
            PrimaryButton(title: "Save this morning", symbol: "checkmark") { Task { await model.saveJournal(journal); dismiss() } }
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var deleteConfirmation = false
    @State private var newTag = ""
    var body: some View {
        SheetFrame(title: "Make yourself at home") {
            Card {
                Eyebrow(text: "Your rhythm")
                Stepper("Sleep target · \(model.state.settings.targetHours.formatted())h", value: $model.state.settings.targetHours, in: 5...12, step: 0.25).font(.subheadline)
                    .onChange(of: model.state.settings.targetHours) { Task { await model.persist() } }
                Toggle("Morning summary", isOn: Binding(get: { model.state.settings.morningNotifications }, set: { enabled in Task {
                    if enabled { model.state.settings.morningNotifications = await model.requestNotifications?() ?? false }
                    else { model.state.settings.morningNotifications = false }
                    await model.persist()
                } })).disabled(model.isDemo)
                Text("Delivery depends on Apple Health and iOS. A summary may arrive later, or after opening sleepi.").font(.caption).foregroundStyle(SleepiTheme.muted)
            }
            Card {
                Eyebrow(text: "Your words")
                ForEach($model.state.tags) { $tag in
                    HStack {
                        TextField("Tag name", text: $tag.name).textFieldStyle(.roundedBorder).onSubmit { Task { await model.persist() } }
                            .foregroundStyle(tag.hidden == true ? SleepiTheme.muted : SleepiTheme.ink)
                        Menu {
                            Button(tag.hidden == true ? "Show in the morning" : "Hide (keeps history)") { Task { await model.setHidden(tag, tag.hidden != true) } }
                            Button("Move up") { Task { await model.moveTagUp(tag) } }
                            Menu("Merge into") {
                                ForEach(model.state.tags.filter { $0.id != tag.id }) { other in Button(other.name) { Task { await model.merge(tag, into: other) } } }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Options for \(tag.name)")
                    }
                }
                HStack { TextField("Your own tag", text: $newTag).textFieldStyle(.roundedBorder); Button("Add") { let value = newTag; newTag = ""; Task { await model.addTag(value) } } }
                Text("Renaming keeps a tag’s history; merging moves every night onto the other tag.").font(.caption).foregroundStyle(SleepiTheme.muted)
            }
            Card {
                Eyebrow(text: "Private by design")
                DetailLine(title: "Health writes", value: "None")
                DetailLine(title: "Cloud sync", value: "Off · local only")
                DetailLine(title: "Clip retention", value: "14 days")
                DetailLine(title: "Clip storage", value: "\(Double(model.usedBytes) / 1_000_000, default: "%.1f") / 300 MB")
                Text("Old clips are removed when sleepi next opens or starts recording. Saved clips count toward the cap; recording stops when they fill it. Notes, tags and settings are included in your iPhone or iCloud backup so they survive a new phone; only clips you haven’t starred are left out.").font(.caption).foregroundStyle(SleepiTheme.muted).lineSpacing(3)
                Button("Review Apple Health access") { Task { await model.connect() } }.disabled(model.isDemo)
                ShareLink(item: model.exportCSV, preview: SharePreview("sleepi nights (CSV)")) { Label("Export sleepi’s data", systemImage: "square.and.arrow.up") }.disabled(model.isDemo)
                Text("One row per night of sleepi’s own data: ratings, tags, time to fall asleep, wake-ups, sleeping heart rate, sound counts and gentle-wake decisions. No audio. Apple’s own data is in the Health app’s export.").font(.caption).foregroundStyle(SleepiTheme.muted)
            }
            Card {
                Eyebrow(text: "A shortcut to tonight")
                Text("In Shortcuts, create a Sleep or Focus automation and add “Open Tonight in sleepi.” It opens the choice screen. Confirm microphone recording on the iPhone.").font(.subheadline).foregroundStyle(SleepiTheme.muted).lineSpacing(4)
            }
            PhoneTrackingCard(model: model)
            if model.watchAvailable { GentleWakeCard(model: model) }
            else {
                // The one place a user looking for Watch features finds a word about them.
                Card {
                    Eyebrow(text: "Apple Watch")
                    Text("Pairing an Apple Watch is the recommended way to use sleepi, but you can still monitor your sleep with your iPhone.").font(.subheadline).foregroundStyle(SleepiTheme.muted).lineSpacing(4)
                }
            }
            Card {
                Eyebrow(text: "A thoughtful experiment")
                Text("\(model.watchAvailable ? "Watch motion and gentle wake are experiments you switch on per night in the Watch app; both start off. " : "")Sleep-stage correction, SRI, a recovery score, and cloud sync are not enabled in this build.").font(.subheadline).foregroundStyle(SleepiTheme.muted).lineSpacing(4)
                Text("sleepi supports reflection on sleep. Sound labels and sleep stages are estimates, not diagnoses.").font(.caption).foregroundStyle(SleepiTheme.muted)
            }
            Button("Delete all local sleepi data", role: .destructive) { deleteConfirmation = true }.disabled(model.isDemo)
                .confirmationDialog("Delete all notes, sessions, settings and recordings from sleepi? Apple Health data is unaffected.", isPresented: $deleteConfirmation, titleVisibility: .visible) {
                    Button("Delete local data", role: .destructive) { Task { await model.deleteLocalData() } }
                }
            Text("sleepi / 0.1 · Personal development build").font(.caption).foregroundStyle(SleepiTheme.muted)
        }.onDisappear { Task { await model.persist() } }
    }
}

struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var page = 0
    @State private var acknowledged = false
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 6) { ForEach(0..<3) { i in Capsule().fill(i == page ? SleepiTheme.lavender : SleepiTheme.card).frame(width: 28, height: 3) } }.padding(.top, 20)
            Spacer()
            Image(systemName: page == 0 ? "moon.stars" : page == 1 ? "heart" : "applewatch").font(.system(size: 56, weight: .ultraLight)).foregroundStyle(SleepiTheme.lavender)
            PageHeading(eyebrow: "Welcome to sleepi", title: page == 0 ? "Rest comes first." : page == 1 ? "Your nights, connected." : "Keep your usual rhythm.", subtitle: page == 0 ? (model.watchAvailable ? "A calm place to understand your sleep, with Apple Watch at its heart." : "A calm place to understand your sleep.") : page == 1 ? "Choose what sleepi may read from Apple Health. You can change access any time." : (model.watchAvailable ? "On your iPhone, check Sleep in Health and the Watch app. These settings aren’t visible to sleepi." : "On your iPhone, check Sleep in the Health app. These settings aren’t visible to sleepi."))
            Text(page == 0 ? "Apple keeps tracking sleep and running your alarm. sleepi never writes Health records or starts a workout. Your notes and optional audio stay on this device." : page == 1 ? "No readable data can mean no recordings or no permission. sleepi cannot tell which. Microphone access is only requested when you start recording." : (model.watchAvailable ? "Enable Track Sleep with Apple Watch. Keep Sleep Focus for Vitals, wear your Watch to bed, and charge it to at least 30%. Confirm your Clock alarm yourself." : "Set your sleep schedule and Sleep Focus as you like. Confirm your Clock alarm yourself.")).font(.subheadline).foregroundStyle(SleepiTheme.muted).lineSpacing(6)
            if page == 2 { Toggle("I’ve checked my Apple sleep setup", isOn: $acknowledged).font(.subheadline) }
            Spacer()
            PrimaryButton(title: page == 0 ? "Get to know your nights" : page == 1 ? "Choose Health access" : "Make yourself at home") {
                if page == 1 { Task { await model.connect(); page = 2 } }
                else if page == 2 { Task { await model.completeOnboarding() } }
                else { page += 1 }
            }.disabled(page == 2 && !acknowledged)
            if page == 1 { Button("Set up Health later") { page = 2 }.frame(maxWidth: .infinity) }
        }.padding(30).frame(minWidth: 340, minHeight: 600).background(SleepiTheme.background).foregroundStyle(SleepiTheme.ink).preferredColorScheme(.dark).tint(SleepiTheme.lavender)
    }
}

/// Window and sensitivity for the Watch's gentle wake, synced both ways, plus the nightly decision logs for tuning.
struct GentleWakeCard: View {
    @Bindable var model: AppModel
    @State private var window = 25.0
    @State private var sensitivity = WakeSensitivity.standard
    var body: some View {
        Card {
            Eyebrow(text: "Gentle wake on Apple Watch")
            Text("Window · \(Int(window)) min before your time").font(.subheadline)
            Slider(value: $window, in: Double(GentleWakeSettings.windowRange.lowerBound)...Double(GentleWakeSettings.windowRange.upperBound), step: 5) { editing in if !editing { save() } }
            Text("Up to 30 minutes: Apple runs a Watch smart alarm for at most 30 minutes. Changes sync with your Watch.").font(.caption).foregroundStyle(SleepiTheme.muted)
            Picker("Movement needed", selection: $sensitivity) {
                ForEach(WakeSensitivity.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).onChange(of: sensitivity) { save() }
            Text("How much sustained restlessness it waits for before tapping. A twitch or a single roll-over never counts; otherwise it taps at your chosen time. Switch it on each night on the Watch.").font(.caption).foregroundStyle(SleepiTheme.muted).lineSpacing(3)
            ForEach(model.wakeLogs.prefix(5)) { log in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(log.windowStart.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                        Text(Self.outcome(log)).font(.caption2).foregroundStyle(SleepiTheme.muted)
                    }
                    Spacer()
                    ShareLink(item: log.csv, preview: SharePreview("sleepi gentle-wake log")) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share this gentle-wake log")
                }
            }
        }
        .onAppear { window = Double(model.gentleWake.windowMinutes); sensitivity = model.gentleWake.sensitivity }
    }
    private func save() { Task { await model.setGentleWake(windowMinutes: Int(window), sensitivity: sensitivity) } }
    static func outcome(_ log: WakeLog) -> String {
        let time = log.tappedAt?.formatted(date: .omitted, time: .shortened) ?? ""
        switch log.outcome {
        case .movement: return "Tapped at \(time) after sustained movement · \(log.sensitivity.title.lowercased())"
        case .deadline: return "Tapped at \(time), your chosen time"
        case .snoozed: return "Tapped at \(time), then snoozed"
        case .endedEarly, nil: return "Ended before a tap"
        }
    }
}

/// Trends for phone-only nights. Every figure except time in bed is an estimate, and says so.
struct PhoneTrends: View {
    @Bindable var model: AppModel
    let nights: [PhoneNight]
    var body: some View {
        if nights.isEmpty {
            EmptyCard(symbol: "chart.xyaxis.line", title: "Patterns take a little time", detail: "Phone nights you track appear here. Missing nights stay missing.")
        } else {
            let asleep = nights.compactMap { $0.estimate?.timeAsleep }
            let inBed = nights.compactMap { n in n.end.map { $0.timeIntervalSince(n.start) } }
            Card {
                Eyebrow(text: "Time asleep · estimate")
                Text(asleep.isEmpty ? "—" : "about " + DurationText.hoursMinutes(asleep.reduce(0, +) / Double(asleep.count))).font(.system(size: 34, weight: .light, design: .rounded))
                Text("Average across \(asleep.count) phone nights").font(.caption).foregroundStyle(SleepiTheme.muted)
                Chart {
                    ForEach(nights) { n in
                        if let t = n.estimate?.timeAsleep { BarMark(x: .value("Night", n.start, unit: .day), y: .value("Hours", t / 3600)).foregroundStyle(SleepiTheme.lavender.gradient).cornerRadius(3) }
                    }
                }.frame(height: 150).accessibilityLabel("Estimated time asleep for \(asleep.count) phone nights")
                DetailLine(title: "In bed (measured)", value: inBed.isEmpty ? "—" : DurationText.hoursMinutes(inBed.reduce(0, +) / Double(inBed.count)))
                let wakes = nights.compactMap { $0.estimate.map { Double($0.wakeUps.count) } }
                DetailLine(title: "Wake-ups per night (estimate)", value: wakes.isEmpty ? "—" : String(format: "%.1f", wakes.reduce(0, +) / Double(wakes.count)))
                let fell = nights.compactMap { $0.estimate?.fellAsleep }.map { Insights.clockMinutes($0, calendar: .current) }
                if let mean = Insights.circularMean(fell) {
                    DetailLine(title: "Fell asleep around (estimate)", value: String(format: "%02d:%02d", Int(mean) / 60, Int(mean) % 60))
                }
                let beds = nights.map { Insights.clockMinutes($0.start, calendar: .current) }
                if beds.count >= 7, let mean = Insights.circularMean(beds) {
                    let spread = sqrt(beds.reduce(0) { $0 + pow(Insights.circularDifference($1, mean), 2) } / Double(beds.count))
                    DetailLine(title: "Bedtime variation (measured)", value: "±\(Int(spread)) min")
                }
                Text("Phones can tell quiet from restless, not sleep stages. An Apple Watch measures sleep stages.").font(.caption).foregroundStyle(SleepiTheme.muted)
            }
        }
    }
}

/// Settings › Phone-only tracking: share a night's log, the hidden test switch, recalculate and the test comparison.
struct PhoneTrackingCard: View {
    @Bindable var model: AppModel
    var body: some View {
        Card {
            Eyebrow(text: "Phone-only tracking")
            let recent = model.phoneNights.filter { $0.end != nil }.suffix(7).reversed()
            if recent.isEmpty { Text("No phone nights yet.").font(.caption).foregroundStyle(SleepiTheme.muted) }
            ForEach(Array(recent)) { night in
                HStack {
                    Text("\(night.start.formatted(date: .abbreviated, time: .shortened))\(night.alongsideWatch == true ? " · test" : "")").font(.caption)
                    Spacer()
                    ShareLink(item: night.logCSV, preview: SharePreview("sleepi night log")) { Label("Share a night’s log", systemImage: "square.and.arrow.up").labelStyle(.iconOnly) }
                        .accessibilityLabel("Share this night’s log")
                }
            }
            Text("Logs are numbers only: sound levels, the room floor, motion counts, phone use and the estimates. No audio.").font(.caption).foregroundStyle(SleepiTheme.muted)
            if model.watchAvailable {
                Toggle("Also run phone tracking on Watch nights", isOn: Binding(get: { model.state.settings.phoneTrackingAlongsideWatch == true },
                                                                                 set: { v in model.state.settings.phoneTrackingAlongsideWatch = v ? true : nil; Task { await model.persist() } })).font(.caption)
                Text("For testing the phone method against your Watch: works on nights started from this iPhone. Results stay out of Last Night and Trends.").font(.caption).foregroundStyle(SleepiTheme.muted)
                ForEach(model.phoneComparisons) { c in
                    let m: (TimeInterval?) -> String = { v in v.map { "\(Int(($0 / 60).rounded())) min" } ?? "—" }
                    Text("\(c.id.addingTimeInterval(86400).formatted(.dateTime.month(.abbreviated).day())): asleep \(m(c.fellAsleepDifference)), woke \(m(c.wokeDifference)), total \(m(c.timeAsleepDifference)), wake-ups ≥5 min \(c.phoneWakeUps) vs \(c.watchWakeUps)")
                        .font(.caption2).foregroundStyle(SleepiTheme.muted)
                }
            }
            Button("Recalculate phone nights") { Task { await model.recalculatePhoneNights() } }.font(.caption)
        }
    }
}
