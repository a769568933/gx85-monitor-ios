import SwiftUI
import UIKit
import GX85Core

struct CameraAlbumView: View {
    @ObservedObject var model: CameraAlbumModel
    let client: CameraMediaClient
    @StateObject private var thumbnails: CameraThumbnailLoader
    @State private var preview: CameraMediaItem?
    @State private var closing = false
    @State private var showExport = false
    @StateObject private var exporter: MediaExportCoordinator
    @Environment(\.dismiss) private var dismiss
    init(model: CameraAlbumModel, client: CameraMediaClient) {
        self.model = model; self.client = client
        _thumbnails = StateObject(wrappedValue: CameraThumbnailLoader(client: client))
        _exporter = StateObject(wrappedValue: MediaExportCoordinator(downloader: MediaDownloadService(cameraHost: client.cameraHost)))
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--fixture-monitor") {
                    Text("模拟相册 · 非相机连接").font(.caption).foregroundStyle(.yellow).padding(8)
                }
                #endif
                if let error = model.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.footnote).foregroundStyle(.yellow)
                        Button("重新载入") { model.reload() }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                if closing { Spacer(); ProgressView("返回监看中"); Spacer() }
                else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 3)], spacing: 10) {
                            ForEach(model.items) { item in
                                VStack(spacing: 4) {
                                    ZStack(alignment: .topTrailing) {
                                        Button {
                                            if item.isContainer { model.enter(item) } else { preview = item }
                                        } label: {
                                            AlbumThumbnail(item: item, loader: thumbnails).aspectRatio(1, contentMode: .fit)
                                                .overlay(alignment: .bottomLeading) {
                                                    if item.kind == .video { Image(systemName: "video.fill").padding(6).foregroundStyle(.white) }
                                                }
                                        }.buttonStyle(.plain)
                                        if !item.isContainer {
                                            Button { model.toggleSelection(item) } label: {
                                                Image(systemName: model.selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                                    .font(.title3).foregroundStyle(model.selection.contains(item.id) ? .blue : .white)
                                                    .frame(width: 44, height: 44).background(.black.opacity(0.25), in: Circle())
                                            }
                                            .buttonStyle(.plain).disabled(item.originalResource == nil)
                                            .accessibilityLabel("选择 \(item.title)")
                                        }
                                    }
                                    Text(item.title).font(.caption2).lineLimit(1)
                                    if !item.isContainer, item.originalResource == nil { Text("仅预览").font(.caption2).foregroundStyle(.secondary) }
                                }
                                .onAppear { if item.id == model.items.last?.id { model.loadNextPage() } }
                            }
                        }
                        .id(model.generation).padding(8)
                        if model.isLoading { ProgressView("读取相机相册").padding() }
                        if model.items.isEmpty && !model.isLoading && model.errorMessage == nil { Text("当前目录没有照片或视频").foregroundStyle(.secondary).padding(40) }
                    }
                    HStack {
                        Text("已选 \(model.selection.count) 项")
                        Spacer()
                        Button("导出原文件") { showExport = true }.disabled(model.selection.isEmpty)
                        Spacer()
                        if let total = model.totalMatches { Text("\(model.items.count) / \(total)") }
                    }.font(.caption).foregroundStyle(.secondary).padding(12)
                }
            }
            .navigationTitle(model.folderTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.path.isEmpty {
                        Button("返回监看") { closing = true; Task { await model.close(); dismiss() } }.disabled(closing)
                    } else { Button("上一级") { model.goBack() } }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { model.loadNextPage() }
        .onChange(of: model.generation) { _ in thumbnails.reset() }
        .sheet(item: $preview) { CameraMediaPreview(item: $0, client: client) }
        .sheet(isPresented: $showExport) { MediaExportView(model: exporter, items: model.selectedItems) }
        .onDisappear { exporter.cancel() }
    }
}

private struct AlbumThumbnail: View {
    let item: CameraMediaItem
    @ObservedObject var loader: CameraThumbnailLoader
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.gray.opacity(0.15)
                if item.isContainer { Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(.blue) }
                else if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                else { Image(systemName: item.kind == .video ? "video" : "photo").foregroundStyle(.secondary) }
            }
        }
        .task(id: item.thumbnailResource?.url) {
            guard let resource = item.thumbnailResource else { return }
            let result = await loader.load(resource)
            guard !Task.isCancelled else { return }
            image = result
        }
        .onDisappear { image = nil }
    }
}
