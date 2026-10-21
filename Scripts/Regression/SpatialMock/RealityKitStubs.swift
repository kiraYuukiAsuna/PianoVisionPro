import simd

struct Transform {
    let scale: SIMD3<Float>
    let rotation: simd_quatf
    let translation: SIMD3<Float>

    var matrix: simd_float4x4 {
        var result = simd_float4x4(rotation)
        result.columns.0 *= scale.x
        result.columns.1 *= scale.y
        result.columns.2 *= scale.z
        result.columns.3 = SIMD4(translation, 1)
        return result
    }
}

extension SIMD3 where Scalar == Float {
    static var one: Self { SIMD3(repeating: 1) }
}
