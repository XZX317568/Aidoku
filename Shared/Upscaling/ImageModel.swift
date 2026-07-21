//
//  ImageModel.swift
//  Aidoku
//
//  Created by Skitty on 6/30/25.
//

// wrapper for coreml image models

import CoreML
import CoreImage
import Vision

class ImageModel: ImageProcessingModel {
    private let model: MLModel
    /// Cached VNCoreMLModel to avoid expensive recreation on every image
    private var cachedVNModel: VNCoreMLModel?

    required init?(model: MLModel, config: [String: Any]) {
        self.model = model
        // Pre-create the VNCoreMLModel at init time
        self.cachedVNModel = try? VNCoreMLModel(for: model)
    }

    func process(_ image: CGImage) async -> CGImage? {
        // Use cached VNCoreMLModel, fall back to creating one if needed
        let vnModel: VNCoreMLModel
        if let cached = cachedVNModel {
            vnModel = cached
        } else if let created = try? VNCoreMLModel(for: model) {
            cachedVNModel = created
            vnModel = created
        } else {
            return nil
        }

        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        try? handler.perform([request])

        guard let result = request.results?.first as? VNPixelBufferObservation else { return nil }

        let image = CIImage(cvImageBuffer: result.pixelBuffer)

        return image.cgImage
    }
}
