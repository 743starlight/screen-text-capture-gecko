// 配る DMG を開いたときの窓の背景を描き、等倍と2倍を1つの TIFF にして書き出す（scripts/make-dmg.sh から呼ぶ）
// 使い方: xcrun swift scripts/dmg-background.swift <書き出す TIFF> <アイコンの絵> <幅> <高さ> <アプリの中心 x> <リンクの中心 x> <アイコンの中心 y>
//   数は pt。make-dmg.sh が、.DS_Store に書くアイコンの位置と同じ数を渡す。
// 左に ScreenTextCapture Gecko、右に Applications（どちらも Finder が描くアイコンと名前）を置き、その間の矢印と下の一言で、ドラッグして入れることを伝える。
// 字は Mac の標準の字体（英字は SF Pro、日本語はヒラギノ角ゴシック）で描く。Finder が描くアイコンの名前や窓の題名と揃い、
// 紹介ページを Mac で見たときの字とも同じになる。この字体は Mac でしか使えないので、Mac で描く。
// 背景の絵を付けた窓を、Finder はライトモードとして描く（アイコンの名前が黒になる）ので、不透明な明るい地にする。
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
let numbers = arguments.dropFirst(2).compactMap { Double($0) }.map { CGFloat($0) }
guard arguments.count == 7, numbers.count == 5,
      let markData = FileManager.default.contents(atPath: arguments[1]),
      let mark = NSBitmapImageRep(data: markData)?.cgImage else {
  FileHandle.standardError.write(Data("使い方: xcrun swift scripts/dmg-background.swift <書き出す TIFF> <アイコンの絵> <幅> <高さ> <アプリの中心 x> <リンクの中心 x> <アイコンの中心 y>\n".utf8))
  exit(2)
}
let width = numbers[0], height = numbers[1], appX = numbers[2], linkX = numbers[3], iconY = numbers[4]

func color(_ hex: Int) -> CGColor {
  CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

// 色は紹介ページと同じ
let paper = color(0xf8f8f7)  // 窓の地
let panel = color(0xefeff1)  // 2つのアイコンを載せる台
let ink = color(0x232427)    // GECKO
let ink2 = color(0x55585e)   // 矢印と一言

// 一言の日本語はヒラギノ角ゴシック（英字の SF Pro の Medium と太さをそろえて W5）。紹介ページの見出しと同じく palt で字の間を詰める
func japaneseFont(size: CGFloat) -> CTFont {
  CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes([
    kCTFontNameAttribute: "HiraginoSans-W5",
    kCTFontFeatureSettingsAttribute: [[kCTFontOpenTypeFeatureTag: "palt", kCTFontOpenTypeFeatureValue: 1]],
  ] as CFDictionary), size, nil)
}

// 英字は font で、かな・漢字・全角の記号は japanese で描く（Mac の画面の字と同じ組み合わせ）。
// 日本語の書体は、字体の代わりの指定（cascade list）に任せると palt が効かないので、字の範囲を指して決める
func textLine(_ text: String, font: CTFont, japanese: CTFont? = nil, color: CGColor, tracking: CGFloat) -> CTLine {
  let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
  let string = NSMutableAttributedString(string: text, attributes: [
    fontKey: font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    NSAttributedString.Key(kCTKernAttributeName as String): tracking,
    NSAttributedString.Key(kCTLanguageAttributeName as String): "ja",
  ])
  if let japanese {
    let ranges = try! NSRegularExpression(pattern: "[\\u3000-\\u9fff\\uff00-\\uffef]+")
    for match in ranges.matches(in: text, range: NSRange(location: 0, length: string.length)) {
      string.addAttribute(fontKey, value: japanese, range: match.range)
    }
  }
  return CTLineCreateWithAttributedString(string)
}

// 左上を原点にした向き（y が下へ増える）のままだと字が逆さになるので、字の向きだけ戻し、基準線の高さを指して描く。
// slant を渡すと、字の上を右へその角度だけ傾ける
func draw(_ line: CTLine, x: CGFloat, baseline: CGFloat, slant: CGFloat = 0, in context: CGContext) {
  context.textMatrix = CGAffineTransform(a: 1, b: 0, c: tan(slant * .pi / 180), d: -1, tx: 0, ty: 0)
  context.textPosition = CGPoint(x: x, y: baseline)
  CTLineDraw(line, context)
}

// 絵も同じく逆さにならないよう、その場だけ向きを戻して描く
func draw(_ image: CGImage, in rect: CGRect, context: CGContext) {
  context.saveGState()
  context.translateBy(x: rect.minX, y: rect.maxY)
  context.scaleBy(x: 1, y: -1)
  context.draw(image, in: CGRect(origin: .zero, size: rect.size))
  context.restoreGState()
}

func drawBackground(in context: CGContext) {
  context.setFillColor(paper)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))

  // 左上のアプリ名。紹介ページのヘッダーと同じく、アイコン（40pt。絵の周りに透ける余白がある）と GECKO を、上から 20〜48pt の行の真ん中にそろえる
  // GECKO は、紹介ページのヘッダーと同じく、SF Pro の太い（900）幅広の斜体。
  // Mac の SF Pro の斜体には幅広が無いので、ブラウザーが斜体を補うときと同じく、幅広の立体を傾ける（傾きは SF Pro の斜体と同じ 12.5°）
  draw(mark, in: CGRect(x: 24, y: 14, width: 40, height: 40), context: context)
  let brand = NSFont.systemFont(ofSize: 19, weight: .black, width: .expanded) as CTFont
  draw(textLine("GECKO", font: brand, color: ink, tracking: 19 * 0.01), x: 72, baseline: 34 + CTFontGetCapHeight(brand) / 2, slant: 12.5, in: context)

  // 2つのアイコンを載せる台。アイコンの名前（Finder がアイコンの下に描く）まで包む。
  // アプリの名前（ScreenTextCapture Gecko）は Finder が2行に折り返すので、その2行目まで入るよう、下を広めにとる
  context.addPath(CGPath(roundedRect: CGRect(x: 56, y: 104, width: width - 112, height: 216), cornerWidth: 22, cornerHeight: 22, transform: nil))
  context.setFillColor(panel)
  context.fillPath()

  // 矢印は、アイコンの間の真ん中に、細いシェブロン（幅 11・高さ 20pt）を4つ、右へ行くほど濃く並べて、流れの向きを見せる
  context.setLineWidth(3)
  context.setLineCap(.round)
  context.setLineJoin(.round)
  let chevrons: [CGFloat] = [0.3, 0.45, 0.65, 0.9]
  let pitch: CGFloat = 11 + 10
  let first = (appX + linkX) / 2 - pitch * CGFloat(chevrons.count - 1) / 2
  for (index, alpha) in chevrons.enumerated() {
    let x = first + pitch * CGFloat(index)
    context.setStrokeColor(ink2.copy(alpha: alpha)!)
    context.move(to: CGPoint(x: x - 5.5, y: iconY - 10))
    context.addLine(to: CGPoint(x: x + 5.5, y: iconY))
    context.addLine(to: CGPoint(x: x - 5.5, y: iconY + 10))
    context.strokePath()
  }

  // 台の下に、真ん中そろえの一言。読みやすさを先に、少し細め（SF Pro の Medium と、ヒラギノの W5）にする
  let hint = textLine("ScreenTextCapture Gecko を Applications へドラッグしてください", font: NSFont.systemFont(ofSize: 14, weight: .medium) as CTFont,
                      japanese: japaneseFont(size: 14), color: ink2, tracking: 0)
  let hintWidth = CGFloat(CTLineGetTypographicBounds(hint, nil, nil, nil))
  draw(hint, x: (width - hintWidth) / 2, baseline: 361, in: context)
}

func render(scale: CGFloat) -> NSBitmapImageRep {
  let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  // CSS と同じく、左上を原点にして pt で描く
  context.translateBy(x: 0, y: height * scale)
  context.scaleBy(x: scale, y: -scale)
  context.interpolationQuality = .high
  drawBackground(in: context)
  let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
  // pt での大きさを持たせて、2倍の絵を 144 dpi として書く（Retina の画面では Finder が2倍の方を使う）
  rep.size = NSSize(width: width, height: height)
  return rep
}

let image = NSImage(size: NSSize(width: width, height: height))
image.addRepresentation(render(scale: 1))
image.addRepresentation(render(scale: 2))
guard let tiff = image.tiffRepresentation(using: .lzw, factor: 0), (try? tiff.write(to: URL(fileURLWithPath: arguments[0]))) != nil else {
  FileHandle.standardError.write(Data("背景の絵を書き出せませんでした: \(arguments[0])\n".utf8))
  exit(1)
}
