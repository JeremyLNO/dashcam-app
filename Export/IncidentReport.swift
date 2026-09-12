import CoreLocation
import Foundation
import PDFKit
import UIKit

/// The one-page PDF that travels with an exported incident.
///
/// The video is the evidence; this is what makes it usable by someone who was not there.
/// An insurer or a police officer receiving a .mov has no idea when it was filmed, where,
/// how fast the car was going, or whether the file they hold is the file that came out of
/// the phone. This page answers those four questions and lists the SHA-256 of every file
/// it travels with.
///
/// It says plainly what it is not: nothing here is signed, and nothing is timestamped by
/// a third party. Overstating that would be worse than saying nothing — a document that
/// implies a guarantee it cannot honour is a document that falls apart at the moment it
/// matters.
struct IncidentReport {
    let session: DriveSession
    let event: ProtectedEvent?
    let files: [URL]
    let digests: [String: String]
    let locationAtEvent: LocationSample?
    let speedKilometresPerHour: Double?

    private let margin: CGFloat = 44
    private let pageSize = CGSize(width: 595, height: 842) // A4 at 72 dpi

    @MainActor
    func write(to url: URL) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        let data = renderer.pdfData { context in
            context.beginPage()
            var y = margin
            y = drawHeader(at: y)
            y = drawSection(title: L10n.t("report.section.drive"), rows: driveRows, at: y)
            if !eventRows.isEmpty {
                y = drawSection(title: L10n.t("report.section.event"), rows: eventRows, at: y)
            }
            if !locationRows.isEmpty {
                y = drawSection(title: L10n.t("report.section.location"), rows: locationRows, at: y)
            }
            y = drawFiles(at: y)
            drawDisclaimer(at: y)
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Content

    private var driveRows: [(String, String)] {
        var rows: [(String, String)] = [
            (L10n.t("report.field.date"), Format.date(session.startedAt)),
            (L10n.t("report.field.start"), Format.time(session.startedAt)),
            (L10n.t("report.field.duration"), Format.duration(session.duration)),
        ]
        if let kilometres = session.distanceKilometres {
            rows.append((L10n.t("report.field.distance"), String(format: "%.2f km", kilometres)))
        }
        rows.append((L10n.t("report.field.cameras"), session.cameraSummary))
        rows.append((L10n.t("report.field.quality"), L10n.t(session.quality.titleKey)))
        rows.append((L10n.t("report.field.timezone"), TimeZone.current.identifier))
        return rows
    }

    private var eventRows: [(String, String)] {
        guard let event else { return [] }
        var rows: [(String, String)] = [
            (L10n.t("report.field.event_kind"), L10n.t(event.origin.titleKey)),
            (L10n.t("report.field.event_time"), Format.time(event.triggerDate)),
            (L10n.t("report.field.window"), "\(Format.time(event.windowStart)) – \(Format.time(event.windowEnd))"),
        ]
        if event.magnitude > 0 {
            rows.append((L10n.t("report.field.peak_g"), String(format: "%.2f g", event.magnitude)))
        }
        return rows
    }

    private var locationRows: [(String, String)] {
        guard let sample = locationAtEvent else { return [] }
        var rows: [(String, String)] = [
            (L10n.t("report.field.coordinates"), String(format: "%.6f, %.6f", sample.latitude, sample.longitude)),
        ]
        if let speed = speedKilometresPerHour {
            rows.append((L10n.t("report.field.speed"), Format.speed(kilometresPerHour: speed)))
        }
        return rows
    }

    // MARK: - Drawing

    private func drawHeader(at y: CGFloat) -> CGFloat {
        var cursor = y
        draw(L10n.t("report.title"), font: .systemFont(ofSize: 24, weight: .bold), at: cursor)
        cursor += 30
        draw(
            L10n.t("report.generated", Format.date(Date()), Format.time(Date())),
            font: .systemFont(ofSize: 11),
            at: cursor,
            colour: .secondaryLabel
        )
        cursor += 18
        draw(appLine, font: .systemFont(ofSize: 11), at: cursor, colour: .secondaryLabel)
        cursor += 26
        line(at: cursor)
        return cursor + 18
    }

    private func drawSection(title: String, rows: [(String, String)], at y: CGFloat) -> CGFloat {
        var cursor = y
        draw(title, font: .systemFont(ofSize: 14, weight: .semibold), at: cursor)
        cursor += 20
        for (label, value) in rows {
            draw(label, font: .systemFont(ofSize: 11), at: cursor, colour: .secondaryLabel)
            draw(value, font: .systemFont(ofSize: 11, weight: .medium), at: cursor, x: margin + 170)
            cursor += 16
        }
        return cursor + 14
    }

    private func drawFiles(at y: CGFloat) -> CGFloat {
        var cursor = y
        draw(L10n.t("report.section.files"), font: .systemFont(ofSize: 14, weight: .semibold), at: cursor)
        cursor += 20
        for file in files {
            draw(file.lastPathComponent, font: .systemFont(ofSize: 11, weight: .medium), at: cursor)
            cursor += 14
            let digest = digests[file.lastPathComponent] ?? L10n.t("report.digest.unavailable")
            // The hash is split across two lines because 64 hex characters do not fit on
            // one at a readable size, and a truncated hash proves nothing at all.
            draw("SHA-256  " + digest.prefix(32), font: .monospacedSystemFont(ofSize: 9, weight: .regular), at: cursor, colour: .secondaryLabel)
            cursor += 12
            draw(String(repeating: " ", count: 9) + digest.suffix(32), font: .monospacedSystemFont(ofSize: 9, weight: .regular), at: cursor, colour: .secondaryLabel)
            cursor += 18
        }
        return cursor + 8
    }

    private func drawDisclaimer(at y: CGFloat) {
        let cursor = max(y, pageSize.height - margin - 74)
        line(at: cursor)
        drawWrapped(
            L10n.t("report.disclaimer"),
            font: .systemFont(ofSize: 9),
            at: cursor + 12,
            width: pageSize.width - margin * 2,
            colour: .secondaryLabel
        )
    }

    private var appLine: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Dashcam Pocket \(version) (\(build)) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }

    private func draw(_ text: String, font: UIFont, at y: CGFloat, x: CGFloat? = nil, colour: UIColor = .label) {
        (text as NSString).draw(
            at: CGPoint(x: x ?? margin, y: y),
            withAttributes: [.font: font, .foregroundColor: colour]
        )
    }

    private func drawWrapped(_ text: String, font: UIFont, at y: CGFloat, width: CGFloat, colour: UIColor) {
        (text as NSString).draw(
            with: CGRect(x: margin, y: y, width: width, height: 60),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font, .foregroundColor: colour],
            context: nil
        )
    }

    private func line(at y: CGFloat) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: y))
        path.addLine(to: CGPoint(x: pageSize.width - margin, y: y))
        UIColor.separator.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}
