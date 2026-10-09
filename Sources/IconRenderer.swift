import AppKit

enum IconRenderer {
    static let size = NSSize(width: 22, height: 22)

    static func image(temperature: Double?, band: TemperatureBand?, disk: Double?,
                      battery: Double?, charging: Bool, appearance _: NSAppearance) -> NSImage {
        // 交给目标屏幕按实际倍率绘制，避免 lockFocus 缓存低分辨率位图。
        let image = NSImage(size: size, flipped: false) { _ in
            // 固定不透明底板隔开壁纸；几何尺寸与用户选定的效果图一致。
            let plate = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 21, height: 21),
                                     xRadius: 4, yRadius: 4)
            color(0x20242C).setFill()
            plate.fill()
            NSColor.white.withAlphaComponent(0.16).setStroke()
            plate.lineWidth = 0.5
            plate.stroke()

            NSGraphicsContext.saveGraphicsState()
            let inset = NSAffineTransform()
            inset.translateX(by: 1.5, yBy: 1.5)
            inset.scale(by: 19 / 22)
            inset.concat()
            // 三条画在深灰底板上，轮廓和缺失标记固定使用深色背景配色。
            draw(temperature: temperature, band: band, disk: disk, battery: battery, charging: charging, dark: true)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = false
        return image
    }

    static func draw(temperature: Double?, band: TemperatureBand?, disk: Double?,
                     battery: Double?, charging: Bool, dark: Bool) {
        // 低温蓝和常态磁盘使用更亮的填充，在深灰底板上清楚显示低读数。
        let blue = color(0x33B5FF)
        let green = color(0x00B444)
        let orange = color(0xFF7800)
        let red = color(0xF51832)
        let ink = color(dark ? 0xFFFFFF : 0x161616)
        let temperatureColor: NSColor
        switch band {
        case .cool: temperatureColor = blue
        case .middle: temperatureColor = green
        case .warm: temperatureColor = orange
        case .hot: temperatureColor = red
        case nil: temperatureColor = ink
        }
        let diskColor: NSColor = (disk ?? 0) >= 0.95 ? red : (disk ?? 0) >= 0.85 ? orange : color(0xC9D4E5)
        let batteryColor: NSColor = (battery ?? 1) <= 0.10 ? red : (battery ?? 1) <= 0.20 ? orange : green
        let values = [temperature.map { $0 / 100 }, disk, battery]
        let colors = [temperatureColor, diskColor, batteryColor]
        for index in 0..<3 {
            let track = NSRect(x: 2 + CGFloat(index) * 6.5, y: 2, width: 5, height: 18)
            let outline = NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5)
            ink.withAlphaComponent(0.08).setFill()
            outline.fill()
            if let value = values[index] {
                NSGraphicsContext.saveGraphicsState()
                outline.addClip()
                colors[index].setFill()
                let fraction = min(1, max(0, value))
                let height = fraction > 0 ? max(1, track.height * fraction) : 0
                NSBezierPath(rect: NSRect(x: track.minX, y: track.minY, width: track.width, height: height)).fill()
                NSGraphicsContext.restoreGraphicsState()
            } else {
                ink.withAlphaComponent(0.90).setFill()
                NSBezierPath(rect: NSRect(x: track.minX + 1, y: 10.5, width: 3, height: 1.5)).fill()
            }
            // 半点轮廓在 Retina 上为一个像素，让低读数时仍看得清完整轨道。
            ink.withAlphaComponent(dark ? 0.38 : 0.40).setStroke()
            let border = NSBezierPath(roundedRect: track.insetBy(dx: 0.25, dy: 0.25), xRadius: 1.25, yRadius: 1.25)
            border.lineWidth = 0.5
            border.stroke()
        }
        if charging && battery != nil {
            green.setFill()
            let dot = NSBezierPath(ovalIn: NSRect(x: 16.5, y: 20, width: 2, height: 2))
            dot.fill()
            ink.withAlphaComponent(0.38).setStroke()
            let dotBorder = NSBezierPath(ovalIn: dot.bounds.insetBy(dx: 0.25, dy: 0.25))
            dotBorder.lineWidth = 0.5
            dotBorder.stroke()
        }
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
