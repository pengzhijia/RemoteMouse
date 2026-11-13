import Foundation
import CoreGraphics

/// Anchor the panel under its menu item using the coordinates of that display.
enum StatusPanelPlacement {
    static func below(anchor:CGRect,size:CGSize,visible:CGRect)->CGRect {
        let inset=visible.insetBy(dx:6,dy:6)
        let x=min(max(anchor.midX-size.width/2,inset.minX),max(inset.minX,inset.maxX-size.width))
        let y=min(max(anchor.minY-size.height,inset.minY),max(inset.minY,inset.maxY-size.height))
        return CGRect(x:x,y:y,width:size.width,height:size.height)
    }
}
