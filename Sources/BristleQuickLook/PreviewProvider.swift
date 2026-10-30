import Foundation
import QuickLookUI
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
  func providePreview(
    for request: QLFilePreviewRequest,
    completionHandler handler: @escaping (QLPreviewReply?, (any Error)?) -> Void
  ) {
    do {
      let scene = try SceneFile.scene(from: Data(contentsOf: request.fileURL))
      let reply = QLPreviewReply(dataOfContentType: .pdf, contentSize: scene.canvas.size) { _ in
        Renderer.pdf(scene, images: ImageStore())
      }
      handler(reply, nil)
    } catch {
      handler(nil, error)
    }
  }
}
