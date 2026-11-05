// 配る DMG を開いたときの窓の設定（ディスクの一番上の .DS_Store）を書く（scripts/make-dmg.sh から呼ぶ）
// 使い方: xcrun swift scripts/dmg-dsstore.swift <開いている DMG の場所> <アプリのファイル名> <幅> <高さ> <アプリの中心 x> <リンクの中心 x> <アイコンの中心 y>
//   数は pt。窓の中の大きさ、アイコンの大きさ（128pt）と位置、背景の絵（.background/background.tiff）を書く。
//   背景の絵を指すしおり（ブックマーク）は、開いているディスクの中のファイルから作るので、DMG を書き込める形で開いてから呼ぶ。
// Finder を AppleScript で操作して書かせる方法（create-dmg と同じ手）は、macOS 26 では使えなかった。窓の大きさとアイコンの位置は
// 残るが、アイコンの大きさ・並べ方・背景は、窓を閉じると Finder が標準の設定で書き戻す（2026-11-04 に確かめた）。
// そこで Finder を通さずに書く。項目と値の形は、macOS 26 で正しく出る他のアプリの DMG（Finder が書いたもの）と、dmgbuild に合わせる。
//
// .DS_Store の形（Finder の「Bud1」形式）: 先頭の見出しから、ブロックの一覧（root block）→ 目次の「DSDB」→ B 木の根と辿る。
// 項目が少ないので、B 木は葉が1つだけの形にする。項目はファイル名（大文字と小文字を区別しない）、項目の名前の順に並べる。
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let numbers = arguments.dropFirst(2).compactMap { Double($0) }
guard arguments.count == 7, numbers.count == 5 else {
  FileHandle.standardError.write(Data("使い方: xcrun swift scripts/dmg-dsstore.swift <開いている DMG の場所> <アプリのファイル名> <幅> <高さ> <アプリの中心 x> <リンクの中心 x> <アイコンの中心 y>\n".utf8))
  exit(2)
}
let volume = URL(fileURLWithPath: arguments[0])
let appName = arguments[1]
let width = numbers[0], height = numbers[1], appX = numbers[2], linkX = numbers[3], iconY = numbers[4]

enum Value {
  case blob(Data)
  case long(UInt32)
}

struct Record {
  let name: String
  let code: String
  let value: Value
}

func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

func plist(_ dictionary: [String: Any]) -> Data {
  try! PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
}

// アイコンの位置（中心）。後ろの 8 バイトは Finder と同じ決まった値
func iconLocation(x: Double, y: Double) -> Data {
  be32(UInt32(x)) + be32(UInt32(y)) + Data([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00])
}

func encode(_ record: Record) -> Data {
  var data = be32(UInt32(record.name.utf16.count))
  for unit in record.name.utf16 { data += Data([UInt8(unit >> 8), UInt8(unit & 0xff)]) }
  data += Data(record.code.utf8)
  switch record.value {
  case .blob(let blob): data += Data("blob".utf8) + be32(UInt32(blob.count)) + blob
  case .long(let number): data += Data("long".utf8) + be32(number)
  }
  return data
}

// 窓の位置は、Finder の書き方（左下を原点にした画面の座標）で、高さ 1440pt の画面なら上から 120pt。
// 小さい画面では Finder が画面の中へ寄せる。大きさには題名の帯（28pt）を含める
let titleBar = 28.0
let windowBounds = "{{200, \(Int(1440 - 120 - height - titleBar))}, {\(Int(width)), \(Int(height + titleBar))}}"
let browserWindow: [String: Any] = [
  "WindowBounds": windowBounds,
  "ShowToolbar": false, "ShowStatusBar": false, "ShowPathbar": false, "ShowTabView": false,
  "ShowSidebar": false, "ContainerShowSidebar": false,
]
// 背景の絵は、ディスクの中のファイルへのしおり（pBBk）で指す。DMG を別の場所に開いても背景が出ることを確かめた。
// 妥協: 古い形の参照（エイリアス。icvp の backgroundImageAlias）は書かない。Foundation では作れないため。
// 将来の macOS で背景が出なくなったら、dmgbuild（mac_alias）と同じ形のエイリアスを作って足す
let backgroundBookmark = try! volume.appendingPathComponent(".background/background.tiff").bookmarkData()
let iconView: [String: Any] = [
  "viewOptionsVersion": 1,
  "backgroundType": 2,
  "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
  "arrangeBy": "none",
  "iconSize": 128.0,
  "textSize": 13.0,
  "axTextSize": 12.0,
  "labelOnBottom": true,
  "showIconPreview": true,
  "showItemInfo": false,
  "gridSpacing": 100.0,
  "gridOffsetX": 0.0, "gridOffsetY": 0.0,
]

let records = [
  Record(name: ".", code: "bwsp", value: .blob(plist(browserWindow))),
  Record(name: ".", code: "icvp", value: .blob(plist(iconView))),
  Record(name: ".", code: "pBBk", value: .blob(backgroundBookmark)),
  Record(name: ".", code: "vSrn", value: .long(1)),
  Record(name: "Applications", code: "Iloc", value: .blob(iconLocation(x: linkX, y: iconY))),
  Record(name: appName, code: "Iloc", value: .blob(iconLocation(x: appX, y: iconY))),
].sorted { ($0.name.lowercased(), $0.code) < ($1.name.lowercased(), $1.code) }

// B 木の葉（ページは 4096 バイト。項目がこれを超えることはない）
var leaf = be32(0) + be32(UInt32(records.count))
for record in records { leaf += encode(record) }
precondition(leaf.count <= 4096, ".DS_Store の項目が 4096 バイトを超えました")

// ブロックの置き場所は、Finder と同じ「buddy allocator」（2 の累乗の大きさのブロックを、半分に割りながら配る）で決める。
// 位置は先頭の 4 バイトの後ろから数え、ブロックの番地は「位置 | 大きさの 2 の指数」で表す
var freeLists = [[UInt32]](repeating: [], count: 32)
freeLists[31] = [0]
func allocate(_ size: Int) -> UInt32 {
  var exponent = 5
  while 1 << exponent < size { exponent += 1 }
  var found = exponent
  while freeLists[found].isEmpty { found += 1 }
  let offset = freeLists[found].removeFirst()
  while found > exponent {
    found -= 1
    freeLists[found].append(offset + (1 << found))
    freeLists[found].sort()
  }
  return offset | UInt32(exponent)
}
func offset(_ address: UInt32) -> Int { Int(address & ~0x1f) }

_ = allocate(32)  // 先頭の見出しの場所
let rootAddress = allocate(2048)
let dsdbAddress = allocate(32)
let leafAddress = allocate(4096)
let blocks = [rootAddress, dsdbAddress, leafAddress]

// 目次「DSDB」の中身: 根のブロックの番号、葉より上の段の数、項目の数、ブロックの数、ページの大きさ
let dsdb = be32(2) + be32(0) + be32(UInt32(records.count)) + be32(1) + be32(0x1000)

// root block: ブロックの番地の一覧（256 個ずつの枠）、目次、空いている場所の一覧（大きさごとに 32 本）
var root = be32(UInt32(blocks.count)) + be32(0)
for address in blocks { root += be32(address) }
root += Data(count: (256 - blocks.count % 256) % 256 * 4)
root += be32(1) + Data([4]) + Data("DSDB".utf8) + be32(1)
for list in freeLists {
  root += be32(UInt32(list.count))
  for free in list { root += be32(free) }
}
precondition(root.count <= 2048, ".DS_Store の root block が 2048 バイトを超えました")

// 見出し: 決まった値「1」と「Bud1」、root block の位置と大きさ（位置はもう一度）。続く 16 バイトは、Finder と同じく葉の番地を先頭に置く
var file = Data(count: 4 + offset(leafAddress) + 4096)
func put(_ data: Data, at position: Int) { file.replaceSubrange(position..<(position + data.count), with: data) }
put(be32(1) + Data("Bud1".utf8) + be32(UInt32(offset(rootAddress))) + be32(2048) + be32(UInt32(offset(rootAddress))) + be32(leafAddress), at: 0)
put(root, at: 4 + offset(rootAddress))
put(dsdb, at: 4 + offset(dsdbAddress))
put(leaf, at: 4 + offset(leafAddress))
do {
  try file.write(to: volume.appendingPathComponent(".DS_Store"))
} catch {
  FileHandle.standardError.write(Data(".DS_Store を書けませんでした: \(error.localizedDescription)\n".utf8))
  exit(1)
}
