import UIKit

extension DeviceKind {
    static var current: DeviceKind {
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
    }
}
