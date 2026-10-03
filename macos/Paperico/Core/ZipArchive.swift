import Foundation
import Compression

/// 最小 ZIP 解包器(App 沙盒内无法调用 /usr/bin/unzip,这里进程内完成)。
///
/// MinerU 结果 ZIP 是标准 deflate 条目;这里解析中央目录并逐条解压,
/// 支持 stored(0) 与 deflate(8),遇到加密或 zip64 条目直接抛错。
enum ZipArchive {

    struct ArchiveError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 解压 `zipURL` 到 `destination`,目录结构按条目名还原。
    static func extract(zipURL: URL, to destination: URL) throws {
        let data = try Data(contentsOf: zipURL)
        try extract(data: data, to: destination)
    }

    static func extract(data: Data, to destination: URL) throws {
        let entries = try centralDirectoryEntries(data)
        guard !entries.isEmpty else {
            throw ArchiveError(message: "ZIP 文件不包含任何条目")
        }
        let fm = FileManager.default
        let root = destination.standardizedFileURL.resolvingSymlinksInPath()
        // Validate every path before creating any files, including existing symlinks.
        let targets = try entries.map { entry -> URL in
            guard !entry.name.isEmpty, !entry.name.hasPrefix("/"),
                  !entry.name.contains("\\"), !entry.name.contains("\0"),
                  !entry.name.split(separator: "/").contains("..") else {
                throw ArchiveError(message: "ZIP 条目包含不安全的路径")
            }
            // Foundation may leave a non-existent final path unresolved. Inspect
            // each existing ancestor so a symlink directory cannot redirect writes.
            var ancestor = root
            for component in entry.name.split(separator: "/") {
                ancestor.appendPathComponent(String(component))
                if let attributes = try? fm.attributesOfItem(atPath: ancestor.path),
                   attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw ArchiveError(message: "ZIP 目标路径包含符号链接")
                }
            }
            let target = root.appendingPathComponent(entry.name).standardizedFileURL.resolvingSymlinksInPath()
            guard target.path.hasPrefix(root.path + "/") else {
                throw ArchiveError(message: "ZIP 条目超出目标目录")
            }
            return target
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for (entry, target) in zip(entries, targets) {
            try Task.checkCancellation()
            if entry.is_directory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            let parent = target.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)

            let payload = try localEntryData(data: data, entry: entry)
            let output: Data
            switch entry.method {
            case 0:
                output = payload
            case 8:
                output = try inflate(payload, expectedSize: entry.uncompressedSize)
            default:
                throw ArchiveError(message: "不支持的 ZIP 压缩方法 \(entry.method)（条目 \(entry.name)）")
            }
            guard output.count == entry.uncompressedSize, crc32(output) == entry.checksum else {
                throw ArchiveError(message: "ZIP 条目长度或校验和不符（条目 \(entry.name)）")
            }
            try output.write(to: target, options: .atomic)
        }
    }

    // MARK: - 中央目录

    private struct Entry {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
        var checksum: UInt32
        var is_directory: Bool { name.hasSuffix("/") }
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    private static func centralDirectoryEntries(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ArchiveError(message: "ZIP 文件被截断") }
        // 扫描 End Of Central Directory 魔数(0x06054b50),从尾部向前找。
        let eocdMagic: UInt32 = 0x0605_4b50
        let scanFloor = max(0, data.count - 66_000)
        var eocdOffset = -1
        var cursor = data.count - 22
        while cursor >= scanFloor {
            if u32(data, cursor) == eocdMagic,
               cursor + 22 + Int(u16(data, cursor + 20)) == data.count {
                eocdOffset = cursor
                break
            }
            cursor -= 1
        }
        guard eocdOffset >= 0 else {
            throw ArchiveError(message: "不是有效的 ZIP 文件（缺少中央目录）")
        }

        let entryCount = Int(u16(data, eocdOffset + 10))
        guard u16(data, eocdOffset + 4) == 0, u16(data, eocdOffset + 6) == 0,
              Int(u16(data, eocdOffset + 8)) == entryCount, entryCount < 20_000 else {
            throw ArchiveError(message: "不支持分卷、zip64 或过多条目的 ZIP")
        }
        var cdOffset = Int(u32(data, eocdOffset + 16))
        let cdEnd = cdOffset + Int(u32(data, eocdOffset + 12))
        guard cdOffset >= 0, cdEnd <= eocdOffset else { throw ArchiveError(message: "ZIP 中央目录越界") }
        var entries: [Entry] = []
        var totalSize = 0

        for _ in 0..<entryCount {
            guard cdOffset + 46 <= cdEnd, u32(data, cdOffset) == 0x0201_4b50 else {
                throw ArchiveError(message: "ZIP 中央目录损坏")
            }
            let method = u16(data, cdOffset + 10)
            let compressedSize = Int(u32(data, cdOffset + 20))
            let uncompressedSize = Int(u32(data, cdOffset + 24))
            let nameLength = Int(u16(data, cdOffset + 28))
            let extraLength = Int(u16(data, cdOffset + 30))
            let commentLength = Int(u16(data, cdOffset + 32))
            let localOffset = Int(u32(data, cdOffset + 42))
            let nextOffset = cdOffset + 46 + nameLength + extraLength + commentLength
            guard nextOffset <= cdEnd, u16(data, cdOffset + 8) & 1 == 0,
                  (u32(data, cdOffset + 38) >> 16) & 0xF000 != 0xA000 else {
                throw ArchiveError(message: "ZIP 条目损坏、加密或包含符号链接")
            }
            let nameData = data.subdata(in: (cdOffset + 46)..<(cdOffset + 46 + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)

            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw ArchiveError(message: "暂不支持 zip64 格式的 ZIP 条目")
            }
            totalSize += uncompressedSize
            guard uncompressedSize <= 256 * 1024 * 1024, totalSize <= 1024 * 1024 * 1024 else {
                throw ArchiveError(message: "ZIP 解压大小超过限制")
            }
            entries.append(Entry(
                name: name,
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset,
                checksum: u32(data, cdOffset + 16)
            ))
            cdOffset = nextOffset
        }
        return entries
    }

    /// 按本地文件头定位条目数据(本地头的名称/额外字段长度可能与中央目录不一致)。
    private static func localEntryData(data: Data, entry: Entry) throws -> Data {
        let offset = entry.localHeaderOffset
        guard offset + 30 <= data.count, u32(data, offset) == 0x0403_4b50 else {
            throw ArchiveError(message: "ZIP 本地文件头损坏（条目 \(entry.name)）")
        }
        guard u16(data, offset + 6) & 1 == 0, u16(data, offset + 8) == entry.method else {
            throw ArchiveError(message: "ZIP 本地条目与中央目录不一致")
        }
        let nameLength = Int(u16(data, offset + 26))
        let extraLength = Int(u16(data, offset + 28))
        let start = offset + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start <= data.count, end <= data.count else {
            throw ArchiveError(message: "ZIP 条目数据越界（条目 \(entry.name)）")
        }
        return data.subdata(in: start..<end)
    }

    // MARK: - deflate 解压

    private static func inflate(_ input: Data, expectedSize: Int) throws -> Data {
        // ZIP 条目是 raw deflate;Compression 的 ZLIB 算法即 raw deflate 流。
        let capacity = max(1, expectedSize)
        var output = Data(count: capacity)
        let decoded = output.withUnsafeMutableBytes { destBuffer -> Int in
            input.withUnsafeBytes { srcBuffer -> Int in
                guard let srcBase = srcBuffer.baseAddress, let destBase = destBuffer.baseAddress else { return 0 }
                return compression_decode_buffer(
                    destBase.assumingMemoryBound(to: UInt8.self), capacity,
                    srcBase.assumingMemoryBound(to: UInt8.self), input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard decoded == expectedSize else {
            throw ArchiveError(message: "ZIP 条目解压失败（数据损坏）")
        }
        output.removeSubrange(decoded..<output.count)
        return output
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
        return crc
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
