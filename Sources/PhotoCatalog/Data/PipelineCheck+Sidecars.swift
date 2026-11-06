import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

extension PipelineCheck.Run {
    /// 12. XMP sidecar write/read roundtrip
    func xmpRoundtrip() {
        var sample = assets[1]
        sample.rating = 4; sample.keywords = ["旅行", "测试"]; sample.title = "标题A"
        sample.caption = "说明B"; sample.colorLabel = .red
        sample.author = "作者B"; sample.copyright = "Copyright B"
        sample.date = XMPSidecar.exifDateFormatter.date(from: "2019-03-08T09:15:00") ?? sample.date
        let xmpURL = tmp.appendingPathComponent("sample.xmp")
        XMPSidecar.write(sample, to: xmpURL)
        if let sc = XMPSidecar.read(xmpURL) {
            check(sc.rating == 4 && sc.keywords == ["旅行", "测试"] && sc.title == "标题A"
                  && sc.caption == "说明B" && sc.colorLabel == .red
                  && sc.author == "作者B" && sc.copyright == "Copyright B"
                  && sc.captureDate == sample.date,
                  "XMP sidecar write/read roundtrip")
        } else { check(false, "XMP sidecar read") }
        // writing over another app's sidecar keeps what it stored there (Lightroom's develop
        // settings, history) and replaces only this app's properties
        let lightroomURL = tmp.appendingPathComponent("lightroom.xmp")
        let lightroom = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmp:Rating="2"
            crs:Exposure2012="+0.50"
            crs:Contrast2012="+12">
           <crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>
           <dc:subject><rdf:Bag><rdf:li>old</rdf:li></rdf:Bag></dc:subject>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        try? lightroom.write(to: lightroomURL, atomically: true, encoding: .utf8)
        var mine = sample
        mine.rating = 5
        mine.keywords = ["new"]
        XMPSidecar.write(mine, to: lightroomURL)
        let mergedText = (try? String(contentsOf: lightroomURL, encoding: .utf8)) ?? ""
        let mergedRead = XMPSidecar.read(lightroomURL)
        check(mergedText.contains("crs:Exposure2012=\"+0.50\"") && mergedText.contains("crs:Contrast2012")
              && mergedText.contains("<crs:ToneCurvePV2012>") && !mergedText.contains(">old<")
              && mergedRead?.rating == 5 && mergedRead?.keywords == ["new"] && mergedRead?.title == sample.title,
              "writing a sidecar keeps another app's data and replaces only ours")
        XMPSidecar.write(mine, to: lightroomURL)
        let rewritten = (try? String(contentsOf: lightroomURL, encoding: .utf8)) ?? ""
        check(rewritten.components(separatedBy: "xmp:Rating=").count == 2
              && rewritten.components(separatedBy: "<dc:subject>").count == 2,
              "writing again doesn't duplicate this app's properties")

        // a sidecar that isn't XMP we can edit is left alone rather than replaced
        let brokenURL = tmp.appendingPathComponent("broken.xmp")
        let broken = Data("<x:xmpmeta><rdf:RDF>another app's half-written file".utf8)
        try? broken.write(to: brokenURL)
        check(!XMPSidecar.write(mine, to: brokenURL) && (try? Data(contentsOf: brokenURL)) == broken,
              "a sidecar that can't be merged isn't written over")
        // text with control characters still makes a sidecar every app can read
        var controlled = sample
        controlled.title = "Tab\tand\u{1}bell\u{7}"
        let controlledURL = tmp.appendingPathComponent("controlled.xmp")
        XMPSidecar.write(controlled, to: controlledURL)
        check(XMPSidecar.read(controlledURL)?.title == "Tab\tandbell", "control characters are left out of a sidecar")
        XMPSidecar.write(mine, to: controlledURL)
        check(XMPSidecar.read(controlledURL)?.rating == 5, "and it can be merged into afterwards")
        // another app's sidecar that says nothing of rating or label leaves them alone; one
        // written as elements, or with the old xap: prefix, is read
        let keywordsOnlyURL = tmp.appendingPathComponent("keywords.xmp")
        try? """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:subject><rdf:Bag><rdf:li>tagged</rdf:li></rdf:Bag></dc:subject>
         </rdf:Description></rdf:RDF></x:xmpmeta>
        """.write(to: keywordsOnlyURL, atomically: true, encoding: .utf8)
        var rated = sample
        if let keywordsOnly = XMPSidecar.read(keywordsOnlyURL) { XMPSidecar.apply(keywordsOnly, to: &rated) }
        check(rated.rating == sample.rating && rated.colorLabel == sample.colorLabel && rated.keywords.first == "tagged",
              "a sidecar without a rating or label leaves the photo's")
        let elementsURL = tmp.appendingPathComponent("elements.xmp")
        try? """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:xap="http://ns.adobe.com/xap/1.0/" xmlns:exif="http://ns.adobe.com/exif/1.0/">
          <xap:Rating>3</xap:Rating>
          <xap:Label>Green</xap:Label>
          <exif:DateTimeOriginal>2020-05-06T07:08:09.00+02:00</exif:DateTimeOriginal>
         </rdf:Description></rdf:RDF></x:xmpmeta>
        """.write(to: elementsURL, atomically: true, encoding: .utf8)
        let elements = XMPSidecar.read(elementsURL)
        check(elements?.rating == 3 && elements?.colorLabel == .green
              && elements?.captureDate == XMPSidecar.exifDateFormatter.date(from: "2020-05-06T07:08:09"),
              "properties written as elements, with the xap: prefix, are read")
        XMPSidecar.write(mine, to: elementsURL)
        let elementsMerged = (try? String(contentsOf: elementsURL, encoding: .utf8)) ?? ""
        check(!elementsMerged.contains("xap:Rating") && XMPSidecar.read(elementsURL)?.rating == 5,
              "writing replaces an xap: rating rather than adding a second one")
    }

    /// 13. import applies an existing XMP sidecar (§6.5 META-006)
    func sidecarImport() {
        xsrc = tmp.appendingPathComponent("xmpsource")
        try? fm.createDirectory(at: xsrc, withIntermediateDirectories: true)
        let ximg = xsrc.appendingPathComponent("PHOTO.jpg")
        writeTestImage(to: ximg, width: 700, height: 500, seed: 5)
        var seed = assets[0]; seed.rating = 3; seed.keywords = ["导入测试"]; seed.colorLabel = .blue
        seed.title = "T"; seed.caption = ""
        seed.author = "Sidecar Author"; seed.copyright = "Sidecar Copyright"
        XMPSidecar.write(seed, to: XMPSidecar.sidecarURL(for: ximg))
        let xa = coordinator.importFolder(xsrc).first
        check(xa?.rating == 3 && xa?.keywords == ["导入测试"] && xa?.colorLabel == .blue
              && xa?.author == "Sidecar Author" && xa?.copyright == "Sidecar Copyright",
              "import applied XMP sidecar metadata")
    }
}
