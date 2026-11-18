import simd

/// A direction as two angles: azimuth to the right of straight ahead, elevation above level.
/// Straight ahead is -z, with x to the right and y up.
struct Bearing {
    var azimuth: Float
    var elevation: Float

    init(azimuth: Float = 0, elevation: Float = 0) {
        self.azimuth = azimuth
        self.elevation = elevation
    }

    init(of direction: SIMD3<Float>) {
        azimuth = atan2(direction.x, -direction.z)
        elevation = asin(min(max(direction.y, -1), 1))
    }

    /// The rotation that turns straight ahead to face this bearing, without rolling.
    var rotation: simd_float3x3 {
        let turn = simd_quatf(angle: -azimuth, axis: SIMD3(0, 1, 0))
        let tilt = simd_quatf(angle: elevation, axis: SIMD3(1, 0, 0))
        return simd_float3x3(turn * tilt)
    }
}

extension simd_float4x4 {
    /// A rotation as a 4×4 matrix, the only matrix size the shader's uniforms use.
    init(rotation: simd_float3x3) {
        self.init(columns: (
            SIMD4(rotation.columns.0, 0),
            SIMD4(rotation.columns.1, 0),
            SIMD4(rotation.columns.2, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }
}

/// The signed difference between two angles, taking the short way round.
func angleDifference(_ a: Float, _ b: Float) -> Float {
    atan2(sin(a - b), cos(a - b))
}
