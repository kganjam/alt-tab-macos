import Cocoa

class AnimationsSheet: SheetWindow {
    override func makeContentView() -> NSView {
        let table = TableGroupView(title: NSLocalizedString("Animations", comment: ""), width: SheetWindow.width)
        let slider = LabelAndControl.makeLabelWithSlider("", "windowDisplayDelay", 0, 900, 19, true, "ms", width: 180)
        let rule = slider[1]
        let indicator = slider[2] as! NSTextField
        indicator.alignment = .right
        indicator.fit(56, indicator.fittingSize.height)
        table.addRow(leftText: NSLocalizedString("Apparition delay of Switcher", comment: ""),
            rightViews: [rule, indicator])
        let coherenceSlider = LabelAndControl.makeLabelWithSlider("", "coherenceDisplayDelay", 0, 900, 19, true, "ms", width: 180)
        let coherenceRule = coherenceSlider[1]
        let coherenceIndicator = coherenceSlider[2] as! NSTextField
        coherenceIndicator.alignment = .right
        coherenceIndicator.fit(56, coherenceIndicator.fittingSize.height)
        table.addRow(leftText: "Parallels Coherence delay",
            rightViews: [coherenceRule, coherenceIndicator])
        table.addRow(leftText: NSLocalizedString("Fade out animation of Switcher", comment: ""),
            rightViews: LabelAndControl.makeSwitch("fadeOutAnimation"))
        table.addRow(leftText: NSLocalizedString("Fade in animation of Preview", comment: ""),
            rightViews: LabelAndControl.makeSwitch("previewFadeInAnimation"))
        return table
    }
}
