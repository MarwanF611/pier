import SwiftUI

struct MusicSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let music = model.music
        SectionCard(title: "Now Playing") {
            if let player = music.nowPlaying?.player, let icon = player.icon {
                HStack(spacing: 4) {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    Text(player.displayName)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } content: {
            if let playing = music.nowPlaying {
                PlayerView(playing: playing)
            } else if let denied = music.permissionDenied {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pier needs permission to control \(denied.displayName).")
                        .font(.callout)
                    Button("Open Privacy Settings") { music.openPrivacySettings() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            } else {
                HStack {
                    Text("Nothing playing")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    ForEach(MusicPlayer.allCases.filter(\.isInstalled)) { player in
                        Button("Open \(player.displayName)") { music.open(player) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

private struct PlayerView: View {
    @Environment(AppModel.self) private var model
    var playing: NowPlaying

    var body: some View {
        let music = model.music
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(playing.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(playing.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 2) {
                    IconButton(symbol: "backward.fill", label: "Previous Track", size: 14) { music.previousTrack() }
                    IconButton(symbol: playing.isPlaying ? "pause.fill" : "play.fill",
                               label: playing.isPlaying ? "Pause" : "Play", size: 20) { music.playPause() }
                        .contentTransition(.symbolEffect(.replace))
                    IconButton(symbol: "forward.fill", label: "Next Track", size: 14) { music.nextTrack() }
                }
                .padding(.leading, -6)
            }
            Spacer(minLength: 0)
        }

        if playing.duration > 0 {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let position = playing.position(at: context.date)
                VStack(spacing: 3) {
                    UsageBar(fraction: position / playing.duration)
                    HStack {
                        Text(position.clock)
                        Spacer()
                        Text("-" + max(0, playing.duration - position).clock)
                    }
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(position.clock) of \(playing.duration.clock)")
            }
        }
    }

    private var artwork: some View {
        ZStack {
            if let image = model.music.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 60, height: 60)
        .background(.primary.opacity(0.08))
        .clipShape(.rect(cornerRadius: 11))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        .accessibilityHidden(true)
    }
}

struct WallpaperSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let wallpapers = model.wallpapers
        SectionCard(title: "Wallpaper") {
            HStack(spacing: 0) {
                IconButton(symbol: "shuffle", label: "Shuffle Wallpaper") { wallpapers.shuffle() }
                Menu {
                    Button("Choose Folder…") { wallpapers.chooseFolder() }
                    if wallpapers.customFolder != nil {
                        Button("Show Only System Wallpapers") { wallpapers.customFolder = nil }
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(.circle)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Wallpaper Folder")
                .accessibilityLabel("Wallpaper Folder")
            }
        } content: {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(wallpapers.wallpapers) { wallpaper in
                        WallpaperThumbnail(wallpaper: wallpaper, isCurrent: wallpaper.url == wallpapers.current)
                    }
                }
                .padding(2)
            }
            .scrollIndicators(.never)
            .frame(height: 62)
            .overlay {
                if wallpapers.wallpapers.isEmpty {
                    Text("No pictures found").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct WallpaperThumbnail: View {
    @Environment(AppModel.self) private var model
    var wallpaper: Wallpaper
    var isCurrent: Bool
    @State private var isHovered = false

    var body: some View {
        Button { model.wallpapers.apply(wallpaper) } label: {
            ZStack {
                Rectangle().fill(.primary.opacity(0.08))
                if let image = model.wallpapers.thumbnail(for: wallpaper) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 92, height: 58)
            .clipShape(.rect(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isCurrent ? Color.accentColor : .primary.opacity(isHovered ? 0.5 : 0.1),
                                  lineWidth: isCurrent ? 2.5 : 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(4)
                }
            }
            .scaleEffect(isHovered ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(wallpaper.name)
        .accessibilityLabel(wallpaper.name)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
