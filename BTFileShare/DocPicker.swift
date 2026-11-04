import UIKit
import UniformTypeIdentifiers

/// Системный выбор файлов поверх текущего экрана (несколько файлов сразу)
enum DocPicker {
    // Держим делегат, пока открыт пикер
    private static var delegate: Delegate?

    static func present(_ onPick: @escaping ([URL]) -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController {
            top = presented
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true

        let d = Delegate(onPick)
        delegate = d
        picker.delegate = d
        top.present(picker, animated: true)
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let handler: ([URL]) -> Void

        init(_ handler: @escaping ([URL]) -> Void) {
            self.handler = handler
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            handler(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            handler([])
        }
    }
}
