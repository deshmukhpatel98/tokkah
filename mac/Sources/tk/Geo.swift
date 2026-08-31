import Foundation
import CoreLocation

// ── WHERE, ONCE, WHEN A CALL CONNECTS ────────────────────────────────────────
//
// The ask (2026-08-31, launch phase): calls will happen from other people's
// Macs at unknown distances, and every latency number this project lives by
// means nothing without the distance it crossed. So: ONE fix per call,
// kilometre accuracy, taken only after the transport locks on a real call --
// never at launch (a permission dialog in front of a doorbell), never for a
// ring preview (nobody agreed to anything yet), and never as a subscription
// (`stopUpdatingLocation` has no work to do because updating never starts).
//
// Two decimal places is ~1.1 km. The beat gets a city block's worth of truth,
// enough to draw the line between two ends and read the RTT against it, and
// no more. A denial is RECORDED (`geo_err`), because an absent number that
// cannot be told from "never asked" is a blind instrument reporting a
// negative.
final class Geo: NSObject, CLLocationManagerDelegate {
  nonisolated(unsafe) static let shared = Geo()
  private var mgr: CLLocationManager?
  private var asked = false

  /// Call when the transport locks on a real call. Safe to call again; only
  /// the first does anything, so a rejoin does not re-prompt mid-sentence.
  func noteCallConnected() {
    DispatchQueue.main.async { [self] in
      guard !asked else { return }
      asked = true
      let m = CLLocationManager()
      mgr = m
      m.delegate = self
      m.desiredAccuracy = kCLLocationAccuracyKilometer
      switch m.authorizationStatus {
      case .notDetermined:
        // The prompt, once per Mac. The fix follows from the delegate's
        // authorization callback -- asking for a location before the person
        // has answered the dialog is refused, not queued.
        m.requestWhenInUseAuthorization()
      case .authorized, .authorizedAlways:
        m.requestLocation()
      default:
        note(err: "denied")
      }
    }
  }

  func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
    guard asked, mgr != nil else { return }
    switch m.authorizationStatus {
    case .authorized, .authorizedAlways: m.requestLocation()
    case .denied, .restricted: note(err: "denied")
    default: break                     // still notDetermined: the dialog is up
    }
  }

  func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
    guard let l = locs.last else { return }
    Metrics.fact("geo_lat", String(format: "%.2f", l.coordinate.latitude))
    Metrics.fact("geo_lon", String(format: "%.2f", l.coordinate.longitude))
    Metrics.fact("geo_acc_km", String(format: "%.1f", max(0, l.horizontalAccuracy) / 1000))
    fputs("geo: \(String(format: "%.2f, %.2f", l.coordinate.latitude, l.coordinate.longitude))"
        + " (±\(Int(max(0, l.horizontalAccuracy))) m) -- recorded once for this call\n", stderr)
    mgr = nil
  }

  func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {
    note(err: (e as NSError).domain == kCLErrorDomain
              && (e as NSError).code == CLError.denied.rawValue ? "denied" : "failed")
  }

  private func note(err: String) {
    Metrics.fact("geo_err", err)
    fputs("geo: no fix (\(err)) -- distance unknown for this call\n", stderr)
    mgr = nil
  }
}
