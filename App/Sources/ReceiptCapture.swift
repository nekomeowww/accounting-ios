import LedgerPersistence
import PhotosUI
import UIKit

enum ReceiptSource { case camera, library }

extension ActivityViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate, PHPickerViewControllerDelegate {
    func scanReceipt(source: ReceiptSource) {
        let settings = AgentSettings.load()
        guard settings.isConfigured, settings.readsImages else {
            let alert = UIAlertController(
                title: "无法识别小票",
                message: settings.isConfigured ? "当前模型没有开启读图片。请换用 Claude、GPT-4o 等模型，并在 AI 设置里打开「模型可以读图片」。" : "还没有配置 AI 服务。",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "去设置", style: .default) { [weak self] _ in
                self?.navigationController?.pushViewController(AgentSettingsViewController(), animated: true)
            })
            present(alert, animated: true)
            return
        }
        if source == .camera, UIImagePickerController.isSourceTypeAvailable(.camera) {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = self
            present(picker, animated: true)
        } else {
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self
            present(picker, animated: true)
        }
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        if let image = info[.originalImage] as? UIImage { sendReceipt(image) }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }
            Task { @MainActor in self?.sendReceipt(image) }
        }
    }

    private func sendReceipt(_ image: UIImage) {
        guard let data = Self.receiptJPEG(image) else { return }
        openChat()?.send("记这张小票", images: [AgentImage(mimeType: "image/jpeg", data: data)])
    }

    private static func receiptJPEG(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 1600 / max(longest, 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.75)
    }
}
