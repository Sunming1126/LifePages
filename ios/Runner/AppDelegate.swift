import CoreImage
import Flutter
import PDFKit
import PhotosUI
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let bookPhotos = BookPhotoPicker()

  override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    FlutterMethodChannel(name: "life_pages/photos", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard ["pick", "pickAvatar"].contains(call.method) else {
          result(FlutterMethodNotImplemented)
          return
        }
        DispatchQueue.main.async {
          guard let self = self, let presenter = Self.presenter() else {
            result(FlutterError(code: "NO_WINDOW", message: "无法打开相册", details: nil))
            return
          }
          self.bookPhotos.present(
            from: presenter,
            maximumDimension: call.method == "pickAvatar" ? 512 : 1600,
            result: result
          )
        }
      }
    let channel = FlutterMethodChannel(name: "life_pages/print", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard ["printBook", "previewBook"].contains(call.method),
            let args = call.arguments as? [String: Any],
            let name = args["name"] as? String, let chapters = args["chapters"] as? [[String: Any]], !chapters.isEmpty else {
        result(FlutterMethodNotImplemented)
        return
      }
      DispatchQueue.main.async {
        guard let presenter = Self.presenter() else {
          result(FlutterError(code: "NO_WINDOW", message: "无法打开书籍窗口", details: nil))
          return
        }
        do {
          let title = args["title"] as? String ?? "\(name)的回忆录"
          let author = args["author"] as? String
          let data = try Self.renderBook(title: title, author: author, chapters: chapters)
          guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw BookPDFError.invalidDocument
          }
          let file = FileManager.default.temporaryDirectory.appendingPathComponent("LifePages-\(UUID().uuidString).pdf")
          try data.write(to: file, options: .atomic)
          if call.method == "previewBook" {
            let reader = BookPDFViewController(document: document, file: file, title: title)
            let navigation = UINavigationController(rootViewController: reader)
            navigation.modalPresentationStyle = .fullScreen
            presenter.present(navigation, animated: true)
          } else {
            let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = presenter.view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: file) }
            presenter.present(sheet, animated: true)
          }
          result(nil)
        } catch {
          result(FlutterError(code: "EXPORT_FAILED", message: "无法生成书籍 PDF", details: nil))
        }
      }
    }
  }

  private static func presenter() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }.first { $0.isKeyWindow }
    guard var presenter = window?.rootViewController else { return nil }
    while let next = presenter.presentedViewController { presenter = next }
    return presenter
  }

  private static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }

  private static func qrImage(_ value: String, context: CIContext) -> UIImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(value.data(using: .utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage,
          let image = context.createCGImage(output, from: output.extent) else { return nil }
    return UIImage(cgImage: image)
  }

  private static func paragraphs(_ text: String) -> String {
    text.components(separatedBy: .newlines)
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map { "<p>\(escape($0))</p>" }.joined()
  }

  static func renderBook(title: String, author: String?, chapters: [[String: Any]]) throws -> Data {
    let paper = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
    let printable = paper.insetBy(dx: 55, dy: 48)
    let cover = "<section class='cover'><div class='eyebrow'>LIFE PAGES</div><h1>\(escape(title))</h1><hr/><p>\(escape(author.map { "\($0) 著" } ?? "时光有声，故事有迹"))</p></section>"
    let qrContext = CIContext()
    let chapterSections = try chapters.enumerated().map { index, chapter -> (html: String, qr: UIImage?) in
      let body: String
      if let blocks = chapter["blocks"] as? [[String: String]] {
        body = try blocks.map { block in
          if let text = block["text"] { return paragraphs(text) }
          guard let image = block["image"], let data = Data(base64Encoded: image),
                UIImage(data: data) != nil else { throw BookPDFError.invalidDocument }
          return "<figure class='photo'><img src='data:image/jpeg;base64,\(image)'/></figure>"
        }.joined()
      } else {
        body = paragraphs(chapter["content"] as? String ?? "")
      }
      let qr: UIImage?
      if let url = chapter["url"] as? String, !url.isEmpty {
        guard let image = qrImage(url, context: qrContext) else { throw BookPDFError.invalidDocument }
        qr = image
      } else {
        qr = nil
      }
      // Keep space for the QR on the chapter's last page. The PDF renderer
      // draws it there after the formatter draws the text.
      let voiceSpace = qr == nil ? "" : "<table class='voice-space' aria-hidden='true'><tr><td>&nbsp;</td></tr></table>"
      let html = "<section class='chapter'><div class='eyebrow'>\(escape(chapter["label"] as? String ?? "第 \(index + 1) 章"))</div><h2>\(escape(chapter["title"] as? String ?? ""))</h2>\(body)\(voiceSpace)</section>"
      return (html, qr)
    }

    func layout(withPages pages: [Int]) -> (NumberedBookRenderer, [Int]) {
      let renderer = NumberedBookRenderer()
      renderer.setValue(paper, forKey: "paperRect")
      renderer.setValue(printable, forKey: "printableRect")
      renderer.footerHeight = 26

      let entries = chapters.enumerated().map { index, chapter in
        let label = escape(chapter["label"] as? String ?? "第 \(index + 1) 章")
        let title = escape(chapter["title"] as? String ?? "")
        let page = pages.isEmpty ? "—" : String(pages[index])
        return "<tr><td class='toc-label'>\(label)</td><td>\(title)</td><td class='toc-page'>\(page)</td></tr>"
      }.joined()
      let toc = "<section class='toc'><h2>目录</h2><table>\(entries)</table></section>"
      var starts: [Int] = []
      var nextPage = 0
      let sections: [(html: String, qr: UIImage?)] = [(cover, nil), (toc, nil)] + chapterSections
      for (index, section) in sections.enumerated() {
        let formatter = UIMarkupTextPrintFormatter(markupText: """
        <!doctype html><html lang="zh-CN"><meta charset="utf-8"><style>
        body { font-family: 'Songti SC', 'PingFang SC', serif; color:#302c27; font-size:12pt; line-height:1.9; overflow-wrap:anywhere; }
        .cover { text-align:center; padding-top:155pt; }
        .cover hr { border:0; border-top:1px solid #97774e; width:48pt; margin:22pt auto; }
        h1 { font-size:32pt; margin:26pt 0; } h2 { font-size:22pt; margin:14pt 0 25pt; }
        .eyebrow { color:#826647; letter-spacing:2pt; font-size:10pt; }
        table { border-collapse:collapse; width:100%; table-layout:fixed; }
        td { padding:6pt 0; border-bottom:1px solid #e6ded2; } tr { page-break-inside:avoid; }
        .toc-label { width:74pt; color:#826647; font-size:10pt; }
        .toc-page { width:36pt; text-align:right; }
        .chapter p { text-indent:2em; margin:0 0 12pt; orphans:2; widows:2; }
        .photo { text-align:center; margin:12pt 0; page-break-inside:avoid; }
        .photo img { max-width:100%; max-height:420pt; }
        .voice-space, .voice-space tr { break-inside:avoid; page-break-inside:avoid; }
        .voice-space td { height:\(NumberedBookRenderer.voiceSpace)pt; padding:0; border:0; }
        </style><body>\(section.html)</body></html>
        """)
        if index >= 2 { starts.append(nextPage) }
        renderer.addPrintFormatter(formatter, startingAtPageAt: nextPage)
        nextPage = renderer.numberOfPages
        if let qr = section.qr { renderer.voiceCodes[nextPage - 1] = qr }
      }
      return (renderer, starts)
    }

    let (_, measuredPages) = layout(withPages: [])
    let (renderer, finalPages) = layout(withPages: measuredPages)
    guard measuredPages == finalPages, renderer.numberOfPages > 0 else { throw BookPDFError.invalidDocument }
    let pageCount = renderer.numberOfPages
    renderer.prepare(forDrawingPages: NSRange(location: 0, length: pageCount))
    let data = NSMutableData()
    UIGraphicsBeginPDFContextToData(data, paper, nil)
    for page in 0..<pageCount {
      UIGraphicsBeginPDFPage()
      renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
    }
    UIGraphicsEndPDFContext()
    return data as Data
  }
}

private final class BookPhotoPicker: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  private var pending: FlutterResult?
  private var maximumDimension: CGFloat = 1600

  func present(from presenter: UIViewController, maximumDimension: CGFloat, result: @escaping FlutterResult) {
    guard pending == nil else {
      result(FlutterError(code: "PICKER_BUSY", message: "相册已打开", details: nil))
      return
    }
    pending = result
    self.maximumDimension = maximumDimension
    if #available(iOS 14.0, *) {
      var configuration = PHPickerConfiguration()
      configuration.filter = .images
      configuration.selectionLimit = 1
      let picker = PHPickerViewController(configuration: configuration)
      picker.delegate = self
      presenter.present(picker, animated: true)
    } else {
      guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else {
        complete(FlutterError(code: "NO_PHOTOS", message: "无法打开相册", details: nil))
        return
      }
      let picker = UIImagePickerController()
      picker.sourceType = .photoLibrary
      picker.delegate = self
      presenter.present(picker, animated: true)
    }
  }

  private func complete(_ value: Any?) {
    let callback = pending
    pending = nil
    callback?(value)
  }

  private func finish(_ image: UIImage?) {
    guard let image = image, max(image.size.width, image.size.height) > 0 else {
      complete(FlutterError(code: "INVALID_PHOTO", message: "无法读取所选图片", details: nil))
      return
    }
    let ratio = min(1, maximumDimension / max(image.size.width, image.size.height))
    let size = CGSize(width: max(1, image.size.width * ratio), height: max(1, image.size.height * ratio))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
      let bounds = CGRect(origin: .zero, size: size)
      context.cgContext.setFillColor(UIColor.white.cgColor)
      context.cgContext.fill(bounds)
      image.draw(in: bounds)
    }
    guard let data = normalized.jpegData(compressionQuality: 0.8), data.count <= 2 * 1024 * 1024 else {
      complete(FlutterError(code: "PHOTO_TOO_LARGE", message: "图片过大，请选择另一张", details: nil))
      return
    }
    complete(FlutterStandardTypedData(bytes: data))
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
    complete(nil)
  }

  func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
    picker.dismiss(animated: true)
    finish(info[.originalImage] as? UIImage)
  }
}

@available(iOS 14.0, *)
extension BookPhotoPicker: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let result = results.first else {
      complete(nil)
      return
    }
    result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] image, _ in
      DispatchQueue.main.async { self?.finish(image as? UIImage) }
    }
  }
}

private enum BookPDFError: Error {
  case invalidDocument
}

private final class NumberedBookRenderer: UIPrintPageRenderer {
  static let voiceSpace: CGFloat = 156
  var voiceCodes: [Int: UIImage] = [:]

  override func drawPage(at pageIndex: Int, in printableRect: CGRect) {
    super.drawPage(at: pageIndex, in: printableRect)
    guard let qr = voiceCodes[pageIndex], let context = UIGraphicsGetCurrentContext() else { return }
    let area = self.printableRect
    let bottom = area.maxY - footerHeight
    let frame = CGRect(x: area.midX - 64, y: bottom - 147, width: 128, height: 128)
    context.saveGState()
    context.setFillColor(UIColor.white.cgColor)
    context.fill(frame)
    context.interpolationQuality = .none
    let quietZone = frame.width * 4 / (qr.size.width + 8)
    qr.draw(in: frame.insetBy(dx: quietZone, dy: quietZone))
    context.restoreGState()

    let caption = NSAttributedString(string: "扫码聆听原声", attributes: [
      .font: UIFont.systemFont(ofSize: 9),
      .foregroundColor: UIColor.darkGray,
    ])
    caption.draw(at: CGPoint(x: area.midX - caption.size().width / 2, y: bottom - 16))
  }

  override func drawFooterForPage(at pageIndex: Int, in footerRect: CGRect) {
    guard pageIndex > 0 else { return }
    let number = NSAttributedString(string: String(pageIndex), attributes: [
      .font: UIFont.systemFont(ofSize: 10),
      .foregroundColor: UIColor.darkGray,
    ])
    let size = number.size()
    number.draw(at: CGPoint(x: footerRect.midX - size.width / 2, y: footerRect.midY - size.height / 2))
  }
}

private final class BookPDFViewController: UIViewController {
  private let document: PDFDocument
  private let file: URL

  init(document: PDFDocument, file: URL, title: String) {
    self.document = document
    self.file = file
    super.init(nibName: nil, bundle: nil)
    self.title = title
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    let reader = PDFView(frame: .zero)
    reader.translatesAutoresizingMaskIntoConstraints = false
    reader.document = document
    reader.displayMode = .singlePageContinuous
    reader.autoScales = true
    view.addSubview(reader)
    NSLayoutConstraint.activate([
      reader.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      reader.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      reader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      reader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    view.backgroundColor = .systemBackground
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "完成", style: .done, target: self, action: #selector(closeBook))
    let share = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareBook(_:)))
    share.accessibilityLabel = "分享书籍"
    let print = UIBarButtonItem(image: UIImage(systemName: "printer"), style: .plain, target: self, action: #selector(printBook(_:)))
    print.accessibilityLabel = "打印书籍"
    navigationItem.rightBarButtonItems = [share, print]
  }

  @objc private func closeBook() { dismiss(animated: true) }

  @objc private func shareBook(_ sender: UIBarButtonItem) {
    let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
    sheet.popoverPresentationController?.barButtonItem = sender
    present(sheet, animated: true)
  }

  @objc private func printBook(_ sender: UIBarButtonItem) {
    let printer = UIPrintInteractionController.shared
    printer.printingItem = file
    if traitCollection.userInterfaceIdiom == .pad {
      printer.present(from: sender, animated: true, completionHandler: nil)
    } else {
      printer.present(animated: true, completionHandler: nil)
    }
  }

  deinit { try? FileManager.default.removeItem(at: file) }
}
