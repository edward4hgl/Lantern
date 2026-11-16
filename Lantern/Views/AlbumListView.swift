import SwiftUI
import Photos
import UIKit

/// 选相簿。共享相簿排最前 —— 这个 App 的核心用法就是把一家人共用的相簿挂墙上。
struct AlbumListView: View {

    @ObservedObject var library: PhotoLibraryService
    @EnvironmentObject private var settings: SlideshowSettings
    @State private var searchText = ""
    @State private var showSettings = false

    var body: some View {
        Group {
            if library.shouldShowSettingsShortcut {
                permissionDeniedView
            } else if !library.isAuthorized {
                requestAccessView
            } else {
                albumList
            }
        }
        .navigationTitle("灯箱")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await library.reloadAlbums() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(library.isLoadingAlbums)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(settings)
        }
        .task {
            library.refreshStatus()
            if library.isAuthorized {
                library.startObservingIfNeeded()
            }
        }
        .task(id: library.revision) {
            guard library.isAuthorized else { return }
            await library.reloadAlbums()
        }
    }

    // MARK: - 列表

    private var albumList: some View {
        List {
            ForEach(sections, id: \.kind) { section in
                Section {
                    ForEach(section.albums) { album in
                        NavigationLink(value: album) {
                            AlbumRow(album: album)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: section.kind.symbol)
                        Text(section.title)
                    }
                    .font(.footnote.weight(.semibold))
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text("在「照片」App 里创建 iCloud 共享相簿并邀请家人，这里就会自动出现。他们往里加的照片会实时进轮播。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "找相簿")
        .overlay {
            if library.albums.isEmpty, !library.isLoadingAlbums {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 40, weight: .ultraLight))
                        .foregroundStyle(.secondary)
                    Text("还没有相簿")
                        .font(.headline)
                    Text("先去「照片」里建一个相簿，或者接受一个共享相簿邀请。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
        }
    }

    private struct SectionModel {
        let kind: AlbumRef.Kind
        let title: String
        let albums: [AlbumRef]
    }

    private var sections: [SectionModel] {
        let filtered = library.albums.filter {
            searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText)
        }
        let grouped = Dictionary(grouping: filtered, by: \.kind)
        let order: [(AlbumRef.Kind, String)] = [
            (.shared, "iCloud 共享相簿"),
            (.user, "我的相簿"),
            (.smart, "智能相簿"),
            (.other, "其他"),
        ]
        return order.compactMap { kind, title in
            guard let list = grouped[kind], !list.isEmpty else { return nil }
            return SectionModel(kind: kind, title: title, albums: list)
        }
    }

    // MARK: - 权限

    private var requestAccessView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.stack")
                .font(.system(size: 46, weight: .ultraLight))
                .foregroundStyle(.tint)
            Text("需要读取你的相簿")
                .font(.title3.weight(.semibold))
            Text("灯箱只读不写：它把你的相簿铺满屏幕，不会改动、删除或上传任何照片。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button("允许访问相簿") {
                Task { await library.requestAccess() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.slash")
                .font(.system(size: 46, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text("相簿权限被关掉了")
                .font(.title3.weight(.semibold))
            Text("去系统设置里打开「照片 → 读取与写入」，回来就能用。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            if let url = URL(string: UIApplication.openSettingsURLString) {
                Button("打开系统设置") {
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding()
    }
}

// MARK: - 行

struct AlbumRow: View {
    let album: AlbumRef

    var body: some View {
        HStack(spacing: 14) {
            AlbumCover(assetID: album.coverAssetID, kind: album.kind)

            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(album.count) 张")
                    Text("·")
                    Text(album.kind.badge)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if album.isEmpty {
                Text("空")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct AlbumCover: View {
    let assetID: String?
    let kind: AlbumRef.Kind

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.secondary.opacity(0.15))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: kind.symbol)
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .task(id: assetID) {
            guard let assetID else { return }
            image = await MediaLoader.shared.thumbnail(for: assetID, side: 54 * UIScreen.main.scale)
        }
    }
}
