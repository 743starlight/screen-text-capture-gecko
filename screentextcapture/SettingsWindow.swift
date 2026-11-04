import AppKit

/// 設定画面は選択に応じて内容の高さが変わり、ウィンドウもそれに合わせて伸び縮みする。
/// 既定のままだと下端を基準に上へ伸びるため、タイトルバーの位置を保って下へ伸び縮みさせる。
/// 伸ばすと画面の下端からはみ出す場合だけ、収まる位置まで上へずらす
final class SettingsWindow: NSWindow {
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(keepingTitleBar(frameRect), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(keepingTitleBar(frameRect), display: displayFlag, animate: animateFlag)
    }

    private func keepingTitleBar(_ proposed: NSRect) -> NSRect {
        guard isVisible, proposed.height != frame.height else { return proposed }
        var rect = proposed
        rect.origin.y = frame.maxY - proposed.height
        if let visible = screen?.visibleFrame, rect.minY < visible.minY { rect.origin.y = visible.minY }
        return rect
    }
}
