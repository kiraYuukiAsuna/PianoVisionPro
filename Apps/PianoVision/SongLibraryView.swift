import SwiftUI

struct SongLibraryView: View {
    @Bindable var session: PianoSession
    let isActive: Bool
    let onSelect: () -> Void
    let onImport: () -> Void

    @State private var searchText = ""
    @State private var favoritesOnly = false
    @FocusState private var isSearchFocused: Bool

    private var favoriteCount: Int { session.library.filter(\.isFavorite).count }
    private var entries: [LibraryEntry] {
        session.libraryEntries(matching: searchText, favoritesOnly: favoritesOnly)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            libraryHeader
            importStatus
            macImportPanel
            libraryControls
            songList
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isActive) { _, active in
            if !active { isSearchFocused = false }
        }
    }

    private var libraryHeader: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Label("我的曲库", systemImage: "music.note.house")
                    .font(.title2.bold())
                Text("\(session.library.count) 首曲目 · \(favoriteCount) 首收藏")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                session.loadDemo()
                onSelect()
            } label: {
                Label("内置练习曲", systemImage: "pianokeys")
            }
            .disabled(session.isImporting)
            Button(action: onImport) {
                Label("导入 MIDI", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent).tint(.cyan)
            .disabled(session.isImporting)
        }
        .libraryPanel()
    }

    @ViewBuilder private var importStatus: some View {
        if session.isImporting || session.bridge.isReceivingFile {
            VStack(alignment: .leading, spacing: 10) {
                if session.bridge.isReceivingFile {
                    HStack {
                        Label("正在接收 Mac 曲目", systemImage: "arrow.down.doc")
                        Spacer()
                        Text(session.bridge.fileTransferProgress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                    ProgressView(value: session.bridge.fileTransferProgress)
                    Text(session.bridge.fileTransferStatus)
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView("正在解析并保存 MIDI…")
                }
            }
            .libraryPanel()
        }
    }

    private var libraryControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索曲目名称", text: $searchText)
                        .focused($isSearchFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除曲目搜索")
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))

                Menu {
                    Picker("曲库排序", selection: $session.librarySortOrder) {
                        ForEach(LibrarySortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                } label: {
                    Label(session.librarySortOrder.title, systemImage: "arrow.up.arrow.down")
                }
                .accessibilityLabel("曲库排序：\(session.librarySortOrder.title)")
            }

            HStack(spacing: 16) {
                Toggle(isOn: $favoritesOnly) {
                    Label("只看收藏", systemImage: "star.fill")
                }
                .toggleStyle(.button)
                .tint(.yellow)
                .accessibilityLabel("只看收藏曲目")
                Text("收藏始终置顶，其余按所选方式排序")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("显示 \(entries.count) 首")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                Picker("曲库显示方式", selection: $session.libraryDisplayMode) {
                    ForEach(LibraryDisplayMode.allCases) { mode in
                        Label(mode.title, systemImage: mode == .list ? "list.bullet" : "square.grid.3x3")
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                if session.libraryDisplayMode == .cards {
                    Picker("每行卡片数", selection: $session.libraryColumnCount) {
                        ForEach(2...4, id: \.self) { count in
                            Text("每行 \(count) 张").tag(count)
                        }
                    }
                    .frame(width: 170)
                }
                Spacer(minLength: 0)
            }
        }
        .libraryPanel()
    }

    @ViewBuilder private var songList: some View {
        let visibleEntries = entries
        let currentEntryID = session.currentLibraryEntryID
        if session.library.isEmpty {
            emptyState(
                title: "曲库还没有曲目",
                message: "导入 MIDI 后会保存在头显中，下次打开仍可使用。也可以先试试内置练习曲。",
                symbol: "music.note.list"
            ) {
                Button("导入 MIDI", action: onImport)
                    .disabled(session.isImporting)
            }
        } else if favoritesOnly && favoriteCount == 0 {
            emptyState(
                title: "还没有收藏曲目",
                message: "点曲目旁的星标即可收藏，收藏的曲目在所有排序中都会排在前面。",
                symbol: "star"
            ) {
                Button("查看全部曲目") { resetFilters() }
            }
        } else if visibleEntries.isEmpty {
            emptyState(
                title: "没有找到匹配曲目",
                message: "试试更短的名称，或清除搜索条件。",
                symbol: "magnifyingglass"
            ) {
                Button("清除搜索") { searchText = "" }
            }
        } else if session.libraryDisplayMode == .cards {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top),
                                     count: session.libraryColumnCount), spacing: 14) {
                ForEach(visibleEntries) { entry in
                    SongLibraryCard(entry: entry, isCurrent: currentEntryID == entry.id,
                                    isImporting: session.isImporting,
                                    onFavorite: { session.toggleFavorite(entry) }, onOpen: { open(entry) })
                }
            }
        } else {
            LazyVStack(spacing: 10) {
                ForEach(visibleEntries) { entry in
                    SongLibraryRow(
                        entry: entry,
                        isCurrent: currentEntryID == entry.id,
                        isImporting: session.isImporting,
                        onFavorite: { session.toggleFavorite(entry) },
                        onOpen: { open(entry) }
                    )
                }
            }
        }
    }

    private var macImportPanel: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("在 Mac 的 PianoBridge 中选择 MIDI 文件或文件夹，发送到头显即可批量加入曲库。文件夹中的子文件夹也会一并导入。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !session.bridge.isConnected {
                    Text("两台设备需在同一局域网，可在“连接”页建立连接。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(session.bridge.fileTransferStatus)
                    .font(.caption).foregroundStyle(.secondary)
                Text("支持 MIDI Format 0 / 1 和曲中变速；曲目保存在本机，无需上传。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 12)
        } label: {
            HStack {
                Label("从电脑导入文件 / 文件夹", systemImage: "desktopcomputer")
                    .font(.headline)
                Spacer()
                Label(session.bridge.isConnected ? "Mac 已连接" : "等待连接 Mac",
                      systemImage: session.bridge.isConnected ? "wifi" : "wifi.slash")
                    .font(.subheadline)
                    .foregroundStyle(session.bridge.isConnected ? Color.green : Color.secondary)
            }
        }
        .libraryPanel()
    }

    private func emptyState<Actions: View>(title: String, message: String, symbol: String,
                                           @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 36)).foregroundStyle(.cyan)
            Text(title).font(.title3.bold())
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 520)
            actions()
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .libraryPanel()
    }

    private func resetFilters() {
        searchText = ""
        favoritesOnly = false
    }

    private func open(_ entry: LibraryEntry) {
        // Returning to the current song keeps its position and held-note state.
        if session.currentLibraryEntryID == entry.id || session.load(entry) {
            onSelect()
        }
    }
}

private struct SongLibraryCard: View {
    let entry: LibraryEntry
    let isCurrent: Bool
    let isImporting: Bool
    let onFavorite: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "pianokeys")
                    .font(.title2).foregroundStyle(isCurrent ? Color.cyan : Color.secondary)
                if isCurrent { Text("当前曲目").font(.caption.bold()).foregroundStyle(.cyan) }
                Spacer(minLength: 0)
                Button(action: onFavorite) {
                    Image(systemName: entry.isFavorite ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundStyle(entry.isFavorite ? Color.yellow : Color.secondary)
                        .frame(width: 48, height: 48)
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).hoverEffect(.highlight)
                .accessibilityLabel(entry.isFavorite ? "取消收藏：\(entry.title)" : "收藏：\(entry.title)")
                .accessibilityValue(entry.isFavorite ? "已收藏" : "未收藏")
            }
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.title).font(.headline).foregroundStyle(.primary).lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
                    Label(PianoSession.timeLabel(entry.duration), systemImage: "clock")
                    Text("\(entry.noteCount) 个音符")
                    if let date = entry.importedAt {
                        Text(date, format: .dateTime.year().month().day())
                            .font(.caption2)
                    } else {
                        Text("导入时间未记录").font(.caption2)
                    }
                    Label(isCurrent ? "继续练习" : "打开曲目", systemImage: isCurrent ? "play.fill" : "arrow.right")
                        .font(.subheadline.bold())
                        .foregroundStyle(isCurrent ? Color.cyan : Color.primary)
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain).hoverEffect(.highlight)
            .disabled(isImporting && !isCurrent)
            .accessibilityLabel(isCurrent ? "继续练习：\(entry.title)" : "打开曲目：\(entry.title)")
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(isCurrent ? 0.09 : 0.055), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 22).strokeBorder(.cyan.opacity(0.35), lineWidth: 1)
            }
        }
    }
}

private struct SongLibraryRow: View {
    let entry: LibraryEntry
    let isCurrent: Bool
    let isImporting: Bool
    let onFavorite: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onFavorite) {
                Image(systemName: entry.isFavorite ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(entry.isFavorite ? Color.yellow : Color.secondary)
                    .frame(width: 52, height: 56)
                    .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(entry.isFavorite ? "取消收藏：\(entry.title)" : "收藏：\(entry.title)")
            .accessibilityValue(entry.isFavorite ? "已收藏" : "未收藏")

            Button(action: onOpen) {
                HStack(spacing: 16) {
                    Image(systemName: isCurrent ? "pianokeys" : "music.note")
                        .font(.title2)
                        .foregroundStyle(isCurrent ? Color.cyan : Color.secondary)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(entry.title).font(.headline).lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if isCurrent {
                                Text("当前曲目")
                                    .font(.caption.bold()).foregroundStyle(.cyan)
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(.cyan.opacity(0.12), in: Capsule())
                                    .fixedSize()
                            }
                        }
                        HStack(spacing: 18) {
                            Label(PianoSession.timeLabel(entry.duration), systemImage: "clock")
                            Text("\(entry.noteCount) 个音符")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        timestamps
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.subheadline.bold()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 16)
                .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .disabled(isImporting && !isCurrent)
            .accessibilityLabel(isCurrent ? "继续练习：\(entry.title)" : "打开曲目：\(entry.title)")
        }
        .padding(8)
        .background(.white.opacity(isCurrent ? 0.09 : 0.055), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 22).strokeBorder(.cyan.opacity(0.35), lineWidth: 1)
            }
        }
    }

    private var timestamps: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let date = entry.importedAt {
                HStack(spacing: 5) {
                    Text("导入于")
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                }
            } else {
                Text("导入时间未记录")
            }
            if let date = entry.lastPlayedAt {
                HStack(spacing: 5) {
                    Text("最近打开")
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                }
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }
}

private extension View {
    func libraryPanel() -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
    }
}
