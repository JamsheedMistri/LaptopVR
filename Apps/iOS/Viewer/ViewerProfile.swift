import Foundation

/// The optics of a phone viewer: where its lenses sit and how they bend the image. These are the
/// same quantities a Google Cardboard QR code carries.
struct ViewerProfile: Codable, Equatable, Sendable {
    /// Which edge of the phone the lens height is measured from.
    enum VerticalAlignment: Int, Codable, Sendable {
        case bottom = 0
        case center = 1
        case top = 2
    }

    var name: String
    /// Distance from the glass to the lenses, in metres.
    var screenToLens: Float
    /// Distance between the two lens centres, in metres.
    var lensSeparation: Float
    var verticalAlignment: VerticalAlignment
    /// Distance from the phone's edge to the lens centres, in metres. Unused when centred.
    var trayToLens: Float
    /// Radial distortion of the lenses: a point at radius r on the glass (in units of
    /// `screenToLens`) appears at tangent-angle r(1 + k1 r² + k2 r⁴).
    var k1: Float
    var k2: Float
    /// Half-angle of the widest view the lenses allow, in degrees.
    var fieldOfView: Float

    static let cardboardV1 = ViewerProfile(
        name: "Cardboard (2014)", screenToLens: 0.042, lensSeparation: 0.060,
        verticalAlignment: .bottom, trayToLens: 0.035, k1: 0.441, k2: 0.156, fieldOfView: 40)

    static let cardboardV2 = ViewerProfile(
        name: "Cardboard (2015)", screenToLens: 0.039, lensSeparation: 0.064,
        verticalAlignment: .bottom, trayToLens: 0.035, k1: 0.34, k2: 0.55, fieldOfView: 60)

    /// For plastic headsets with adjustable lenses and no QR code. The one a new install starts
    /// with.
    static let generic = ViewerProfile(
        name: "Generic headset", screenToLens: 0.040, lensSeparation: 0.063,
        verticalAlignment: .center, trayToLens: 0, k1: 0.22, k2: 0.24, fieldOfView: 50)

    static let presets = [generic, cardboardV2, cardboardV1]

    /// Phone bezel between the tray and the first row of pixels, as Cardboard assumes it.
    private static let bezel: Float = 0.003

    /// Height of the lens centres above the bottom of the glass, for a screen this tall.
    func lensHeight(screenHeight: Float) -> Float {
        switch verticalAlignment {
        case .bottom: trayToLens - Self.bezel
        case .center: screenHeight / 2
        case .top: screenHeight - (trayToLens - Self.bezel)
        }
    }

    /// How many pixels cover one degree at the centre of the view.
    func pixelsPerDegree(pixelsPerMeter: Float) -> Float {
        pixelsPerMeter * screenToLens * .pi / 180
    }
}
