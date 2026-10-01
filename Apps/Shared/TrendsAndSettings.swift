import SwiftUI
import Charts
import SleepiCore

struct TrendsView: View {
    @Bindable var model: AppModel
    @State private var days = 30
    private var nights: [SleepNight] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now)!
        return model.nights.filter { $0.windowEnd >= cutoff }
    }
    var body: some View {
        PageHeading(eyebrow: "Look at the longer story", title: "Patterns, without pressure.", subtitle: "One night is a moment. A few weeks tell you more.")
        Picker("Time range", selection: $days) { Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90) }.pickerStyle(.segmented)
        if nights.isEmpty {
            EmptyCard(symbol: "chart.xyaxis.line", title: "Patterns take a little time", detail: "Once Apple Watch has recorded your nights, you’ll see duration and schedule variation here. Missing nights stay missing.")
        } else {
            Card {
                Eyebrow(text: "Time asleep")
                Text(DurationText.hoursMinutes(nights.reduce(0) { $0 + $1.asleepSeconds } / Double(nights.count))).font(.system(size: 34, weight: .light, design: .rounded))
                Text("Average across \(nights.count) recorded nights").font(.caption).foregroundStyle(SleepiTheme.muted)
                Chart {
                    ForEach(nights) { n in
                        BarMark(x: .value("Night", n.lastSleep ?? n.windowEnd, unit: .day), y: .value("Hours", n.asleepSeconds / 3600)).foregroundStyle(SleepiTheme.lavender.gradient).cornerRadius(3)
                    }
                    RuleMark(y: .value("Target", model.state.settings.targetHours)).foregroundStyle(SleepiTheme.muted.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                }.chartYScale(domain: 0...max(10, (nights.map { $0.asleepSeconds / 3600 }.max() ?? 0) + 1)).chartYAxis { AxisMarks(position: .leading) }.frame(height: 170)
                    .accessibilityLabel("Sleep duration chart for \(nights.count) recorded nights")
                Text("Dashed line: your \(model.state.settings.targetHours.formatted())h target. No data is filled into missing nights.").font(.caption).foregroundStyle(SleepiTheme.muted)
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
                let shortfall = Insights.shortfall(nights: model.nights, targetHours: model.state.settings.targetHours, now: .now)
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
                Eyebrow(text: "What goes with better nights?")
                let comparisons = model.state.tags.compactMap { tag -> (JournalTag, TagComparison)? in
                    guard let comparison = Insights.comparison(tagID: tag.id, nights: nights, journals: model.state.journals) else { return nil }; return (tag, comparison)
                }
                if comparisons.isEmpty { Text("Your notes will tell the story.").font(.title3); Text("Comparisons need 10 reviewed nights with a tag and 10 without it. Save a note even on nights with no tags. Associations don’t show cause and effect.").font(.caption).foregroundStyle(SleepiTheme.muted).lineSpacing(3) }
                ForEach(comparisons, id: \.0.id) { tag, comparison in
                    Text(tag.name).font(.headline)
                    DetailLine(title: "With · \(comparison.withTagCount) nights", value: DurationText.hoursMinutes(comparison.withTagSeconds))
                    DetailLine(title: "Without · \(comparison.withoutTagCount) nights", value: DurationText.hoursMinutes(comparison.withoutTagSeconds))
                }
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
                ForEach(model.state.tags) { tag in
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
                ForEach($model.state.tags) { $tag in TextField("Tag name", text: $tag.name).textFieldStyle(.roundedBorder).onSubmit { Task { await model.persist() } } }
                HStack { TextField("New tag", text: $newTag).textFieldStyle(.roundedBorder); Button("Add") { let value = newTag.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { model.state.tags.append(JournalTag(name: value)); newTag = ""; Task { await model.persist() } } } }
            }
            Card {
                Eyebrow(text: "Private by design")
                DetailLine(title: "Health writes", value: "None")
                DetailLine(title: "Cloud sync", value: "Off · local only")
                DetailLine(title: "Clip retention", value: "14 days")
                DetailLine(title: "Clip storage", value: "\(Double(model.usedBytes) / 1_000_000, default: "%.1f") / 300 MB")
                Text("Old clips are removed when sleepi next opens or starts recording. Saved clips count toward the cap; recording stops when they fill it. Notes and audio are excluded from backups.").font(.caption).foregroundStyle(SleepiTheme.muted).lineSpacing(3)
                Button("Review Apple Health access") { Task { await model.connect() } }.disabled(model.isDemo)
            }
            Card {
                Eyebrow(text: "A shortcut to tonight")
                Text("In Shortcuts, create a Sleep or Focus automation and add “Open Tonight in sleepi.” It opens the choice screen. Confirm microphone recording on the iPhone.").font(.subheadline).foregroundStyle(SleepiTheme.muted).lineSpacing(4)
            }
            Card {
                Eyebrow(text: "A thoughtful experiment")
                Text("Watch motion and gentle wake are experiments you switch on per night in the Watch app; both start off. Sleep-stage correction, SRI, a recovery score, and cloud sync are not enabled in this build.").font(.subheadline).foregroundStyle(SleepiTheme.muted).lineSpacing(4)
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
            PageHeading(eyebrow: "Welcome to sleepi", title: page == 0 ? "Rest comes first." : page == 1 ? "Your nights, connected." : "Keep your usual rhythm.", subtitle: page == 0 ? "A calm place to understand your sleep, with Apple Watch at its heart." : page == 1 ? "Choose what sleepi may read from Apple Health. You can change access any time." : "On your iPhone, check Sleep in Health and the Watch app. These settings aren’t visible to sleepi.")
            Text(page == 0 ? "Apple keeps tracking sleep and running your alarm. sleepi never writes Health records or starts a workout. Your notes and optional audio stay on this device." : page == 1 ? "No readable data can mean no recordings or no permission. sleepi cannot tell which. Microphone access is only requested when you start recording." : "Enable Track Sleep with Apple Watch. Keep Sleep Focus for Vitals, wear your Watch to bed, and charge it to at least 30%. Confirm your Clock alarm yourself.").font(.subheadline).foregroundStyle(SleepiTheme.muted).lineSpacing(6)
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
