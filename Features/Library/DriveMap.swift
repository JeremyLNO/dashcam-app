import CoreLocation
import MapKit
import SwiftUI

/// Where the drive went, and where the events happened on it.
///
/// The positions were already being recorded — they fed a distance and an optional
/// overlay, and were otherwise invisible. Drawn, they answer the question a timeline
/// cannot: *where* was I when that happened. Tapping an event pin moves the player to it,
/// so the map is a second way into the same footage rather than a decoration.
///
/// Everything here is local. MapKit renders Apple's tiles, and no position ever leaves
/// the phone — the app has no server to send them to.
struct DriveMap: View {
    let samples: [LocationSample]
    let events: [ProtectedEvent]
    let startedAt: Date
    let onSelectEvent: (TimeInterval) -> Void

    @State private var camera: MapCameraPosition = .automatic

    private var coordinates: [CLLocationCoordinate2D] {
        samples.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates)
                    .stroke(Theme.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }

            if let first = coordinates.first {
                Annotation(L10n.t("map.start"), coordinate: first) {
                    endpoint(colour: Theme.success, systemImage: "flag.fill")
                }
            }
            if let last = coordinates.last, coordinates.count > 1 {
                Annotation(L10n.t("map.end"), coordinate: last) {
                    endpoint(colour: Theme.textPrimary, systemImage: "flag.checkered")
                }
            }

            ForEach(eventPins, id: \.event.id) { pin in
                Annotation(L10n.t(pin.event.origin.titleKey), coordinate: pin.coordinate) {
                    Button {
                        onSelectEvent(max(0, pin.event.triggerDate.timeIntervalSince(startedAt)))
                    } label: {
                        IconBadge(
                            systemImage: pin.event.origin.symbolName,
                            accent: pin.event.origin == .impact ? .coral : .orange,
                            size: 34
                        )
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .softShadow()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous))
        .allowsHitTesting(true)
    }

    private func endpoint(colour: Color, systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .padding(7)
            .background(Circle().fill(colour))
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
    }

    /// Each event placed at the position recorded closest to when it fired. An event with
    /// no position within ten seconds gets no pin at all rather than a pin somewhere
    /// plausible — a map that guesses is worse than a map that admits a gap.
    private var eventPins: [(event: ProtectedEvent, coordinate: CLLocationCoordinate2D)] {
        events.compactMap { event in
            let nearest = samples.min {
                abs($0.timestamp.timeIntervalSince(event.triggerDate)) < abs($1.timestamp.timeIntervalSince(event.triggerDate))
            }
            guard let nearest, abs(nearest.timestamp.timeIntervalSince(event.triggerDate)) <= 10 else { return nil }
            return (event, CLLocationCoordinate2D(latitude: nearest.latitude, longitude: nearest.longitude))
        }
    }
}
