import SwiftUI

/// 设置。全部即时生效，没有「保存」按钮 —— 挂墙的场景里，用户是站在 iPad 前面边看边调的。
struct SettingsSheet: View {

    @EnvironmentObject private var settings: SlideshowSettings
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReset = false

    var body: some View {
        NavigationStack {
            Form {
                timingSection
                mediaSection
                lookSection
                watermarkSection
                behaviourSection
                aboutSection
            }
            .navigationTitle("播放设置")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("恢复默认设置？", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("恢复默认", role: .destructive) {
                    settings.resetAll()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("节奏、顺序、外观、行为都会回到初始值。记住的播放位置不受影响。")
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - 节奏

    private var timingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("照片停留")
                    Spacer()
                    Text("\(Int(settings.photoInterval)) 秒")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.photoInterval, in: 2...60, step: 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("视频停留")
                    Spacer()
                    Text(videoHoldLabel)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.videoInterval, in: 0...180, step: 1)
                Text(settings.videoInterval < 0.5
                     ? "整段播完自动翻页。"
                     : "超过视频本身的时长时，按整段播完算。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Picker(selection: $settings.order) {
                ForEach(SlideOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            } label: {
                Label("顺序", systemImage: "arrow.up.arrow.down")
            }
        } header: {
            Text("节奏")
        }
    }

    /// 视频停留的读数：0 显示成「播完为止」，否则显示秒数并提醒会被时长封顶。
    private var videoHoldLabel: String {
        settings.videoInterval < 0.5 ? "播完为止" : "\(Int(settings.videoInterval)) 秒"
    }

    // MARK: - 素材

    private var mediaSection: some View {
        Section {
            Toggle(isOn: $settings.playLivePhotos) {
                Label("播放实况照片", systemImage: "livephoto")
            }
            Toggle(isOn: $settings.skipVideos) {
                Label("跳过视频", systemImage: "video.slash")
            }
            Toggle(isOn: $settings.videoAudio) {
                Label("视频声音", systemImage: settings.videoAudio ? "speaker.wave.2" : "speaker.slash")
            }
            .disabled(settings.skipVideos)
            Toggle(isOn: $settings.videoHDUpgrade) {
                Label("视频自动升清晰", systemImage: "wand.and.stars")
            }
            .disabled(settings.skipVideos)
            Toggle(isOn: $settings.videoDiskCache) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("留下看过的高清视频", systemImage: "internaldrive")
                    Text("存最近 3 个，下次同一个视频直接高清起播。关掉会立刻清空。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(settings.skipVideos || !settings.videoHDUpgrade)
        } header: {
            Text("素材")
        }
    }

    // MARK: - 外观

    private var lookSection: some View {
        Section {
            Picker(selection: $settings.transition) {
                ForEach(TransitionStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            } label: {
                Label("切换效果", systemImage: "sparkles")
            }

            NavigationLink {
                FitSettingsView()
            } label: {
                HStack {
                    Label("画面填充", systemImage: "aspectratio")
                    Spacer()
                    Text(fitSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("推近幅度", systemImage: "plus.magnifyingglass")
                    Spacer()
                    Text(String(format: "%.0f%%", settings.kenBurnsZoom * 100))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.kenBurnsZoom, in: 0...0.25, step: 0.01)
                    .disabled(settings.transition != .kenBurns && settings.transition != .random)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("画面压暗", systemImage: "moon.fill")
                    Spacer()
                    Text(String(format: "%.0f%%", settings.dimLevel * 100))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.dimLevel, in: 0...0.8, step: 0.05)
            }
        } header: {
            Text("外观")
        } footer: {
            Text("夜里把画面压暗一点，眼睛舒服，也不容易烧屏。")
        }
    }

    // MARK: - 水印（日期 / 地点 / 日期计算）

    /// 「画面填充」行右边的摘要：四种素材里有几个是铺满。
    private var fitSummary: String {
        let modes = FitTarget.allCases.map { settings.fitMode(for: $0) }
        let fillCount = modes.filter { $0 == .fill }.count
        if fillCount == modes.count { return "全部铺满" }
        if fillCount == 0 { return "全部完整" }
        return "铺满 \(fillCount) · 完整 \(modes.count - fillCount)"
    }

    /// 左下角那几行的开关与文案。填一个日期（生日 / 结婚纪念 / 开业那天），
    /// 每张照片底下就会自动写「宝宝 2岁3个月」。
    private var watermarkSection: some View {
        Section {
            Toggle(isOn: $settings.showCaptureDate) {
                Label("显示拍摄日期", systemImage: "calendar")
            }

            Toggle(isOn: $settings.showPlace) {
                Label("显示拍摄地点", systemImage: "location")
            }
            .disabled(!settings.showCaptureDate)

            Toggle(isOn: $settings.showAgeLabel) {
                Label("显示日期计算", systemImage: "figure.child")
            }

            if settings.showAgeLabel {
                TextField("称呼", text: $settings.subjectName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Toggle(isOn: birthdayOn) {
                    Label("设置日期", systemImage: "calendar.badge.clock")
                }

                if settings.subjectBirthday != nil {
                    DatePicker("日期",
                               selection: birthdayBinding,
                               in: ...Date(),
                               displayedComponents: .date)

                    TextField("格式", text: $settings.ageTemplate)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Text("预览")
                        Spacer()
                        Text(previewText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        } header: {
            Text("水印")
        } footer: {
            Text("日期与地点在左下角，一直可见，不随控制条消失。地点靠系统反查相册里存的坐标，没坐标的照片就不显示。\n日期计算：填一个日期（孩子生日、结婚纪念、开业那天都行），格式里可用 {name}（称呼）和 {age}（按每张照片的拍摄日期算出的时间），例如「{name} {age}」会写成「宝宝 2岁3个月」。")
        }
    }

    /// 「设置日期」开关：打开时若还没有日期，默认填两年前（照片墙最常见的是拍小孩）。
    private var birthdayOn: Binding<Bool> {
        Binding(
            get: { settings.subjectBirthday != nil },
            set: { on in
                if on {
                    if settings.subjectBirthday == nil {
                        settings.subjectBirthday = Calendar.current.date(byAdding: .year, value: -2, to: Date())
                    }
                } else {
                    settings.subjectBirthday = nil
                }
            }
        )
    }

    private var birthdayBinding: Binding<Date> {
        Binding(
            get: { settings.subjectBirthday ?? Date() },
            set: { settings.subjectBirthday = $0 }
        )
    }

    /// 用「今天」当拍摄日期做样例，让人当场看到格式对不对。
    private var previewText: String {
        AgeLabel.text(birthday: settings.subjectBirthday,
                      at: Date(),
                      name: settings.subjectName,
                      template: settings.ageTemplate) ?? "—"
    }

    // MARK: - 行为

    private var behaviourSection: some View {
        Section {
            Toggle(isOn: $settings.showClock) {
                Label("显示时钟", systemImage: "clock")
            }
            Toggle(isOn: $settings.showProgress) {
                Label("视频进度条", systemImage: "chart.bar")
            }
            Toggle(isOn: $settings.resumeLastPosition) {
                Label("记住上次位置", systemImage: "bookmark")
            }

            Button(role: .destructive) {
                confirmingReset = true
            } label: {
                Label("恢复默认设置", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("行为")
        } footer: {
            Text("视频进度条在控制条上方，可以按住拖动跳到任意位置。照片不画进度条 —— 它只有停留时间，「第几张 / 共几张」已经在左上角标着，而且这个读数在本页显示期间不会变。")
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            HStack {
                Text("版本")
                Spacer()
                Text(Bundle.main.shortVersion)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Bundle ID")
                Spacer()
                Text(Bundle.main.bundleIdentifier ?? "-")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("关于")
        } footer: {
            Text("灯箱 · 共享相簿 · 自动轮播")
        }
    }
}

extension Bundle {
    var shortVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - 画面填充（四套独立设置）

/// 四类素材的取舍本来就不一样：竖照片铺满会切掉头顶，横视频铺满几乎没损失。
/// 一个全局开关必然牺牲两类，所以让它们各管各的。
struct FitSettingsView: View {

    @EnvironmentObject private var settings: SlideshowSettings

    var body: some View {
        Form {
            Section {
                picker(for: .photoPortrait)
                picker(for: .photoLandscape)
            } header: {
                Text("照片")
            } footer: {
                Text("铺满 = 填满整屏，超出部分裁掉；完整显示 = 全部看得到，空出来的地方用同一张图模糊垫底。")
            }

            Section {
                picker(for: .videoPortrait)
                picker(for: .videoLandscape)
            } header: {
                Text("视频")
            } footer: {
                Text("视频的选择与照片独立 —— 竖屏视频铺满通常更好看，横屏视频完整显示通常更安全。")
            }
        }
        .navigationTitle("画面填充")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func picker(for target: FitTarget) -> some View {
        Picker(selection: binding(for: target)) {
            ForEach(FitMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        } label: {
            Label(target.label, systemImage: symbol(for: target))
        }
    }

    private func binding(for target: FitTarget) -> Binding<FitMode> {
        Binding(
            get: { settings.fitMode(for: target) },
            set: { settings.setFitMode($0, for: target) }
        )
    }

    private func symbol(for target: FitTarget) -> String {
        switch target {
        case .photoPortrait:  return "rectangle.portrait"
        case .photoLandscape: return "rectangle"
        case .videoPortrait:  return "rectangle.portrait.fill"
        case .videoLandscape: return "rectangle.fill"
        }
    }
}
