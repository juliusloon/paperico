import SwiftUI
import ImageIO

/// Local file images must be decoded from disk; AsyncImage's HTTP loader cannot
/// reliably load file URLs. Downsampling and a bounded cache keep long papers light.
struct LocalPaperImage: View {
    let url: URL
    var minimumHeight: CGFloat = 120
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark").font(.system(size: 28))
                    Text("图像无法读取").font(.caption)
                }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: minimumHeight)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: minimumHeight)
            }
        }
        .task(id: url) {
            image = nil
            failed = false
            let loaded = await Task.detached(priority: .utility) { LocalImageCache.load(url) }.value
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }
}

private enum LocalImageCache {
    static let images: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 80
        return cache
    }()

    static func load(_ url: URL) -> CGImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path):\(modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        images.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}
