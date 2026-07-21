//
//  UpscaleProcessor.swift
//  Aidoku
//
//  Created by Skitty on 6/24/25.
//

import Foundation
import Nuke

import Vision

#if os(iOS) || os(tvOS)
import UIKit
#else
import CoreGraphics
import ImageIO
#endif

struct UpscaleProcessor: ImageProcessing {
    /// Special model file name indicating the built-in native enhancer
    static let nativeModelIdentifier = "__native_enhance__"

    var identifier: String {
        "com.github.Aidoku/Aidoku/upscale"
    }

    func process(_ image: PlatformImage) -> PlatformImage? {
        guard let cgImage = image.cgImage else { return image }

        // ensure an upscaling model is enabled
        guard let enabledModel = ModelManager.shared.getEnabledModelFileName() else {
            return image
        }

        // ensure image is smaller than max height
        let maxHeight = UserDefaults.standard.integer(forKey: "Reader.upscaleMaxHeight")
        guard cgImage.height < maxHeight else { return image }

        // Use built-in native enhancer (no model download required)
        if enabledModel == Self.nativeModelIdentifier {
            guard let output = NativeEnhanceModel.shared.process(cgImage) else {
                return image
            }
#if os(iOS) || os(tvOS)
            return PlatformImage(cgImage: output, scale: UIScreen.main.scale, orientation: image.imageOrientation)
#else
            return PlatformImage(cgImage: output, size: .init(width: image.size.width, height: image.size.height))
#endif
        }

        // Use CoreML model-based upscaling
        return BlockingTask {
            let model: ImageProcessingModel
            do {
                guard let imageModel = try await ModelManager.shared.getEnabledModel() else {
                    throw ProcessorError.invalidModel
                }
                model = imageModel
            } catch {
                LogManager.logger.error("Unable to load enabled upscaling model: \(error)")
                return image
            }
            guard let output = await model.process(cgImage) else {
                LogManager.logger.error("Upscaling model failed to process image")
                return image
            }
#if os(iOS) || os(tvOS)
            return await PlatformImage(cgImage: output, scale: UIScreen.main.scale, orientation: image.imageOrientation)
#else
            return PlatformImage(cgImage: output, size: .init(width: image.size.width, height: image.size.height))
#endif
        }.get()
    }

    enum ProcessorError: Error {
        case invalidModel
    }
}
