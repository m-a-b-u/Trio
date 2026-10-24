#if os(macOS)
    import SwiftUI
    import WidgetKit

    @main struct TrioMacWidgetBundle: WidgetBundle {
        var body: some Widget {
            TrioStatusWidget()
        }
    }
#endif
