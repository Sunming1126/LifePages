import PDFKit
import UIKit
import Vision
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {
  @MainActor
  func testBookPDFContainsScannableChapterQR() throws {
    let url = "https://example.test/lifepages/listen/test-share-9c273eb6d42fae7c"
    let body = Array(repeating: String(repeating: "村口的桃树开花了。", count: 16), count: 25)
      .joined(separator: "\n") + "\n这段讲述到这里。"
    let data = try AppDelegate.renderBook(title: "回忆录", author: nil, chapters: [
      ["title": "故乡的轮廓", "content": body, "url": url],
      ["title": "家族的记忆", "content": "这是第二章的正文。", "url": ""],
    ])
    let book = try XCTUnwrap(PDFDocument(data: data))
    XCTAssertGreaterThan(book.pageCount, 4)
    XCTAssertTrue(book.page(at: book.pageCount - 1)?.string?.contains("这是第二章的正文") == true)
    var codes: [(Int, String)] = []
    for index in 0..<book.pageCount {
      let page = try XCTUnwrap(book.page(at: index))
      let thumbnail = page.thumbnail(of: CGSize(width: 950, height: 1343), for: .mediaBox)
      let image = try XCTUnwrap(thumbnail.cgImage)
      let request = VNDetectBarcodesRequest()
      request.symbologies = [.qr]
      try VNImageRequestHandler(cgImage: image).perform([request])
      codes += (request.results ?? []).compactMap { barcode in
        barcode.payloadStringValue.map { (index, $0) }
      }
    }
    XCTAssertEqual(codes.map { $0.0 }, [book.pageCount - 2])
    XCTAssertEqual(codes.map { $0.1 }, [url])
  }
}
