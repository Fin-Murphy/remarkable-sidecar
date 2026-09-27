import Foundation

struct DirtyRect {
    var x, y, w, h: Int
}

/// Compares two grayscale frames in 64x64 tiles. Horizontally adjacent dirty tiles in a tile
/// row become one rect; rects with the same x-span in consecutive tile rows are merged.
func dirtyRects(old: [UInt8], new: [UInt8], width: Int, height: Int, tile: Int = 64) -> [DirtyRect] {
    let cols = (width + tile - 1) / tile
    let rows = (height + tile - 1) / tile

    func tileDirty(_ tx: Int, _ ty: Int) -> Bool {
        let x0 = tx * tile, w = min(tile, width - x0)
        let y0 = ty * tile, h = min(tile, height - y0)
        return old.withUnsafeBufferPointer { (a: UnsafeBufferPointer<UInt8>) -> Bool in
            new.withUnsafeBufferPointer { (b: UnsafeBufferPointer<UInt8>) -> Bool in
                for y in y0..<(y0 + h) {
                    let offset = y * width + x0
                    if memcmp(a.baseAddress! + offset, b.baseAddress! + offset, w) != 0 { return true }
                }
                return false
            }
        }
    }

    var done: [DirtyRect] = []
    var open: [DirtyRect] = []  // rects that reach the bottom of the previous tile row
    for ty in 0..<rows {
        let y0 = ty * tile, h = min(tile, height - y0)
        var next: [DirtyRect] = []
        var tx = 0
        while tx < cols {
            guard tileDirty(tx, ty) else { tx += 1; continue }
            let start = tx
            while tx < cols && tileDirty(tx, ty) { tx += 1 }
            var run = DirtyRect(x: start * tile, y: y0, w: min(tx * tile, width) - start * tile, h: h)
            if let i = open.firstIndex(where: { $0.x == run.x && $0.w == run.w }) {
                run = open.remove(at: i)
                run.h += h
            }
            next.append(run)
        }
        done += open
        open = next
    }
    return done + open
}
