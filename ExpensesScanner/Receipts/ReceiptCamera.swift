import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import Vision

/**
 * One receipt, one tap: the camera takes a single photo, cuts the receipt out of it and squares it up.
 * (Apple's document scanner is made for many pages and keeps asking for the next one.)
 */
struct ReceiptCamera: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> ReceiptCameraController {
        let controller = ReceiptCameraController()
        controller.onCapture = onCapture
        controller.onCancel = onCancel
        return controller
    }

    func updateUIViewController(_ controller: ReceiptCameraController, context: Context) {}
}

final class ReceiptCameraController: UIViewController, AVCapturePhotoCaptureDelegate {
    var onCapture: ((UIImage) -> Void)?
    var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let preview = AVCaptureVideoPreviewLayer()
    private let sessionQueue = DispatchQueue(label: "receipt-camera")
    private let shutter = UIButton(type: .custom)
    private let spinner = UIActivityIndicatorView(style: .large)
    private let hint = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        preview.session = session
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)

        var cancel = UIButton.Configuration.plain()
        cancel.title = L10n.cancel
        cancel.baseForegroundColor = .white
        let cancelButton = UIButton(configuration: cancel, primaryAction: UIAction { [weak self] _ in self?.onCancel?() })

        hint.text = L10n.cameraHint
        hint.textColor = .white
        hint.font = .preferredFont(forTextStyle: .subheadline)
        hint.adjustsFontForContentSizeCategory = true
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.layer.shadowColor = UIColor.black.cgColor
        hint.layer.shadowOpacity = 0.8
        hint.layer.shadowRadius = 4
        hint.layer.shadowOffset = .zero

        shutter.backgroundColor = .white
        shutter.layer.cornerRadius = 34
        shutter.layer.borderWidth = 5
        shutter.layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor
        shutter.isEnabled = false
        shutter.accessibilityLabel = L10n.takePhoto
        shutter.addAction(UIAction { [weak self] _ in self?.capture() }, for: .touchUpInside)

        spinner.color = .white
        spinner.hidesWhenStopped = true

        for subview in [cancelButton, hint, shutter, spinner] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            cancelButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            cancelButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            hint.bottomAnchor.constraint(equalTo: shutter.topAnchor, constant: -20),
            shutter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutter.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -24),
            shutter.widthAnchor.constraint(equalToConstant: 68),
            shutter.heightAnchor.constraint(equalToConstant: 68),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        startWhenAllowed()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let session = session
        sessionQueue.async { session.stopRunning() }
    }

    private func startWhenAllowed() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { granted ? self.configure() : self.showNoAccess() }
            }
        default:
            showNoAccess()
        }
    }

    private func configure() {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input), session.canAddOutput(output)
            else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.showNoAccess() }
                return
            }
            session.addInput(input)
            session.addOutput(output)
            output.maxPhotoQualityPrioritization = .quality
            session.commitConfiguration()
            session.startRunning()
            DispatchQueue.main.async { self.shutter.isEnabled = true }
        }
    }

    private func showNoAccess() {
        hint.text = L10n.cameraNoAccess
        shutter.isHidden = true
    }

    private func capture() {
        shutter.isEnabled = false
        spinner.startAnimating()
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        if output.supportedFlashModes.contains(.auto) { settings.flashMode = .auto }
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        output.capturePhoto(with: settings, delegate: self)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = error == nil ? photo.fileDataRepresentation().flatMap(UIImage.init(data:)) : nil
        let receipt = image.map { DocumentCrop.receipt(in: $0) ?? $0 }
        DispatchQueue.main.async {
            self.spinner.stopAnimating()
            if let receipt {
                self.onCapture?(receipt)
            } else {
                self.shutter.isEnabled = true
            }
        }
    }
}

/// Finds the receipt in a photo and squares it up, like a scanner would.
enum DocumentCrop {
    /// The receipt cut out and straightened; nil when no document stands out clearly.
    static func receipt(in photo: UIImage) -> UIImage? {
        let upright = ReceiptScanner.upright(photo, width: min(photo.size.width, 2000))
        guard let image = upright.cgImage else { return nil }
        let request = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        guard let document = request.results?.first, document.confidence >= 0.5,
              document.boundingBox.width * document.boundingBox.height >= 0.08
        else { return nil }
        // Vision's corners are normalised with the origin at the bottom left, as Core Image's are.
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        func point(_ corner: CGPoint) -> CGPoint { CGPoint(x: corner.x * width, y: corner.y * height) }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = CIImage(cgImage: image)
        filter.topLeft = point(document.topLeft)
        filter.topRight = point(document.topRight)
        filter.bottomLeft = point(document.bottomLeft)
        filter.bottomRight = point(document.bottomRight)
        guard let output = filter.outputImage,
              let cropped = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cropped)
    }
}
