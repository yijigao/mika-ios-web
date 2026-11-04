import CoreGraphics

enum DrawerDismissPolicy {
    static func shouldDismiss(translationWidth: CGFloat) -> Bool { translationWidth < -60 }
}
