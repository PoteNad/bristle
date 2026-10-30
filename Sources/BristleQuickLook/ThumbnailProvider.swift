import Foundation
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
  override func provideThumbnail(
    for request: QLFileThumbnailRequest,
    _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void
  ) {
    do {
      let scene = try SceneFile.scene(from: Data(contentsOf: request.fileURL))
      let page = scene.canvas.size
      guard page.width > 0, page.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
      let size = request.maximumSize
      let scale = min(size.width / page.width, size.height / page.height)
      let drawn = CGSize(width: page.width * scale, height: page.height * scale)
      let origin = CGPoint(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2)
      let reply = QLThumbnailReply(contextSize: size) { context in
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: origin.x, y: origin.y + drawn.height)
        context.scaleBy(x: scale, y: -scale)
        Renderer.draw(scene, in: context, rect: scene.canvas, images: ImageStore())
        return true
      }
      reply.extensionBadge = "bristle"
      handler(reply, nil)
    } catch {
      handler(nil, error)
    }
  }
}
