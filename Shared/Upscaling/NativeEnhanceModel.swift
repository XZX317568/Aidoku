//
//  NativeEnhanceModel.swift
//  Aidoku
//
//  Built-in image enhancement using Core Image filters.
//  No external model download required — uses Lanczos upscaling,
//  luminance sharpening, and optional noise reduction.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Metal

/// A lightweight image enhancer that uses Core Image's built-in filters
/// to upscale and sharpen manga/comic pages without requiring a CoreML model.
class NativeEnhanceModel {
    static let shared = NativeEnhanceModel()

    private let context: CIContext

    private init() {
        // Use Metal-backed context for GPU acceleration
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
    }

    /// Process an image with native enhancement.
    /// - Parameters:
    ///   - image: The source CGImage to enhance
    ///   - scaleFactor: Upscale factor (default 2.0)
    ///   - sharpenIntensity: Sharpen intensity 0.0-1.0 (default from UserDefaults)
    /// - Returns: Enhanced CGImage or nil on failure
    func process(
        _ image: CGImage,
        scaleFactor: CGFloat = 2.0,
        sharpenIntensity: CGFloat? = nil
    ) -> CGImage? {
        let inputImage = CIImage(cgImage: image)

        // Step 1: Lanczos upscale for high-quality interpolation
        let lanczosFilter = CIFilter.lanczosScaleTransform()
        lanczosFilter.inputImage = inputImage
        lanczosFilter.scale = Float(scaleFactor)
        lanczosFilter.aspectRatio = 1.0

        guard var outputImage = lanczosFilter.outputImage else { return nil }

        // Step 2: Boost contrast to make manga lines crisper (black blacker, white whiter)
        let contrastAmount = UserDefaults.standard.double(forKey: "Reader.nativeEnhanceContrast")
        if contrastAmount != 0 {
            let contrastFilter = CIFilter.colorControls()
            contrastFilter.inputImage = outputImage
            contrastFilter.contrast = Float(1.0 + contrastAmount)
            contrastFilter.brightness = 0
            contrastFilter.saturation = 1
            if let contrasted = contrastFilter.outputImage {
                outputImage = contrasted
            }
        }

        // Step 3: Sharpen luminance to restore edge crispness after upscaling
        let intensity = sharpenIntensity
            ?? CGFloat(UserDefaults.standard.double(forKey: "Reader.nativeEnhanceSharpen"))
        if intensity > 0 {
            let sharpenFilter = CIFilter.unsharpMask()
            sharpenFilter.inputImage = outputImage
            sharpenFilter.radius = Float(2.0)
            sharpenFilter.intensity = Float(intensity)
            if let sharpened = sharpenFilter.outputImage {
                outputImage = sharpened
            }
        }

        // Step 4: Optional noise reduction for cleaner flat areas
        let noiseReduction = UserDefaults.standard.double(forKey: "Reader.nativeEnhanceDenoise")
        if noiseReduction > 0 {
            let denoiseFilter = CIFilter.noiseReduction()
            denoiseFilter.inputImage = outputImage
            denoiseFilter.noiseLevel = Float(noiseReduction)
            denoiseFilter.sharpness = 0.4
            if let denoised = denoiseFilter.outputImage {
                outputImage = denoised
            }
        }

        // Render final output
        return context.createCGImage(outputImage, from: outputImage.extent)
    }
}
