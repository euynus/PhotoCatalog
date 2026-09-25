// ============================================================
//  GPXParser — track points (trkpt) with time from a .gpx file
// ============================================================
import Foundation

enum GPXParser {
    /// Track points that carry a time; nil when the file isn't readable GPX.
    static func parse(_ data: Data) -> GPXTrack? {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return GPXTrack(points: delegate.points)
    }

    static func parse(contentsOf url: URL) -> GPXTrack? {
        (try? Data(contentsOf: url)).flatMap(parse)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var points: [GPXPoint] = []
        private var current: (lat: Double, lon: Double)?
        private var elevation: Double?
        private var time: Date?
        private var text = ""
        private let fractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private let plain = ISO8601DateFormatter()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String]) {
            text = ""
            let local = name.split(separator: ":").last.map(String.init) ?? name
            if local == "trkpt" || local == "rtept",
               let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init) {
                current = (lat, lon)
                elevation = nil
                time = nil
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch local {
            case "ele" where current != nil:
                elevation = Double(value)
            case "time" where current != nil:
                time = fractional.date(from: value) ?? plain.date(from: value)
            case "trkpt", "rtept":
                if let current, let time {
                    points.append(GPXPoint(latitude: current.lat, longitude: current.lon, elevation: elevation, time: time))
                }
                current = nil
            default:
                break
            }
            text = ""
        }
    }
}
