// Copyright (c) 2026 Pingolin LLC
//
// This file is part of Pingolin Track.
//
// Pingolin Track is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Pingolin Track is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Pingolin Track. If not, see <https://www.gnu.org/licenses/>.

import UIKit
import MapLibre
import CoreLocation

/// Member annotation payload. Wraps MLNPointAnnotation with the data
/// `MemberMarkerView` needs to render the Android-parity bitmap
/// (52pt colored circle, 2-char initials, age label below). Color is
/// resolved upstream by `MapView` using the same per-member palette
/// the Android app picks (MEMBER_COLORS in MapViewModel).
final class MemberAnnotation: MLNPointAnnotation {
    var memberId: String = ""
    var displayName: String = ""
    var ageMs: Int64 = 0
    /// When the shown position was taken, in ms since 1970. `ageMs` is worked
    /// out from it by each pass and by the map's clock in between.
    var fixTimeMs: Int64 = 0
    var fillColor: UIColor = MemberPalette.colors[0]
    var isCurrentUser: Bool = false
    /// Name of the saved place the member is currently inside, or nil.
    /// When set, the marker shows "At <Place>" and the place's own pin is
    /// hidden — matching android's member-at-place behaviour.
    var atPlaceName: String?
    /// This member has an active SOS. Marks the avatar with an "SOS" band
    /// under the initials and a red halo pulsing out from under it, instead
    /// of stamping a separate SOS disc over the top of them.
    var hasSOS: Bool = false
    /// The radius, in metres, of the area this member is somewhere inside when
    /// they share only an approximate location; nil = a position.
    /// The avatar sits at the area's centre (`ApproximateAreaPolygon`).
    var approximateMeters: Double?
    /// The last location they shared before switching real-time sharing off,
    /// frozen: grey, with "Location sharing off" for its caption.
    var sharingOff = false
}

/// The area an approximate member is somewhere inside, drawn translucent in
/// their colour under their avatar (`ApproximateArea`). A polygon of points on
/// the circle, because shape annotations are what MapLibre keeps across a style
/// change; one per member, replaced when its centre or size changes.
final class ApproximateAreaPolygon: MLNPolygon {
    var memberId: String = ""
    var center = CLLocationCoordinate2D()
    var radiusMeters: Double = 0
    var fillColor: UIColor = MemberPalette.stale
}

final class PlaceAnnotation: MLNPointAnnotation {
    var placeId: String = ""
    /// SF Symbol id of the place's icon (used as the fallback when
    /// the place doesn't carry an emoji glyph).
    var icon: String = "mappin.circle.fill"
    var hexColor: String = "#3B82F6"
    /// True when the place is owned by another circle member and
    /// shared with us; mirrors the Android app's dashed-border
    /// style for shared places. Solid border otherwise.
    var isShared: Bool = false
}

final class DestinationAnnotation: MLNPointAnnotation {
    var destinationId: String = ""
    /// Creator's palette color (resolved upstream like the member dots),
    /// so a destination reads as "whose" at a glance — mirrors
    /// the Android app's per-creator destination color.
    var fillColor: UIColor = MemberPalette.colors[0]
}

final class DroppedPinAnnotation: MLNPointAnnotation {}

/// An active SOS. Cross-circle: unlike members/places/destinations these are
/// NOT filtered to the selected circle, because an emergency elsewhere still
/// has to be visible.
final class SOSAnnotation: MLNPointAnnotation {
    var sosId: String = ""
    /// "Sent from here · 12m", drawn under the disc.
    ///
    /// This marker only appears when the raiser has MOVED away from where they
    /// raised (or has no avatar at all) — see the merge pass in
    /// MapLibreMapView. Without it, two identical red triangles sit on the map
    /// with nothing saying which is the person and which is the place they
    /// left. "from" carries "this is the origin"; the age carries "this is not
    /// current".
    var caption: String = ""
    /// An alert shown as an AREA: its label, drawn by
    /// `SOSAreaLabelView` in place of the disc. nil for a point, which keeps it.
    var areaLabel: String?
    /// The alert as the last pass had it, so the map's clock can move the
    /// caption's age on in between.
    var alert: SOSAlert?
}

/// Manual-clustering payload. When two or more member markers would
/// visually overlap at the current zoom, the Coordinator collapses
/// them into ONE of these and renders a `ClusterMarkerView` count
/// badge instead of the individual avatars. We cluster in SCREEN
/// space ourselves — native MapLibre clustering (MLNShapeSource
/// `clusterOptions`) does NOT work in this MapLibre fork (the
/// engine never emits cluster features and silently drops points
/// below the threshold), so this is the only path that renders.
/// Mirrors the Android app's screen-space member clustering.
/// `memberIds` is the set collapsed into this badge (sorted+joined
/// forms the Coordinator's stable group key); `count` is its size.
final class ClusterAnnotation: MLNPointAnnotation {
    var memberIds: [String] = []
    var count: Int = 0
    /// Stable group key (sorted member ids joined by ","), the same key
    /// the Coordinator stores this badge under in `clusterAnnotations`.
    /// Stamped at creation so the fan-out tap handler can tell whether
    /// the tapped cluster is already the open one without recomputing
    /// the key from memberIds.
    var key: String = ""
}

/// Fan-out (spiderfy) display copy of a member. When a cluster badge is
/// tapped, its members are spread into a ring of these around the badge
/// so coincident avatars can be tapped individually — the Android app's
/// cluster spiderfy behavior. These are SEPARATE annotations positioned
/// at fanned coordinates; the real `MemberAnnotation` coordinates are
/// never moved (that would corrupt re-clustering). The fan dismisses on
/// the next camera settle. Rendered with the same `MemberMarkerView` as
/// a real member, so a fanned avatar is visually identical to its
/// in-place counterpart.
final class FanMemberAnnotation: MLNPointAnnotation {
    var memberId = ""
    var displayName = ""
    var ageMs: Int64 = 0
    var fillColor: UIColor = MemberPalette.colors[0]
    var isCurrentUser = false
    var atPlaceName: String?
    var hasSOS: Bool = false
    var isApproximate = false
    var sharingOff = false
}

/// Per-member color palette. Indexed by member position in the
/// circle's member list, modulo length. Same 8 values as
/// the Android app's `MapViewModel.MEMBER_COLORS` — bright
/// variants chosen for contrast against both light and dark map
/// styles.
enum MemberPalette {
    static let colors: [UIColor] = [
        UIColor(hex: "#818CF8") ?? .systemIndigo,   // Indigo
        UIColor(hex: "#4ADE80") ?? .systemGreen,    // Emerald
        UIColor(hex: "#F9A8D4") ?? .systemPink,     // Pink
        UIColor(hex: "#FCD34D") ?? .systemYellow,   // Amber
        UIColor(hex: "#93C5FD") ?? .systemBlue,     // Blue
        UIColor(hex: "#C4B5FD") ?? .systemPurple,   // Purple
        UIColor(hex: "#FCA5A5") ?? .systemRed,      // Red
        UIColor(hex: "#5EEAD4") ?? .systemTeal,     // Teal
    ]
    /// Gray bucket used when a member's last update is older than the
    /// stale threshold (matches Android `Color.parseColor("#9e9e9e")`).
    static let stale = UIColor(hex: "#9E9E9E") ?? .systemGray
    /// 15 minutes — matches the web client and the Android app.
    static let staleThresholdMs: Int64 = 15 * 60 * 1_000

    static func color(forIndex index: Int) -> UIColor {
        guard !colors.isEmpty else { return .systemBlue }
        return colors[((index % colors.count) + colors.count) % colors.count]
    }

    /// THE colour of one member's bubble. Every surface that draws a member —
    /// the map marker, the member card, the circle roster — must come through
    /// here: sites that each look the member up in a roster of their own
    /// choosing, and each do something different when the lookup misses,
    /// render one member in two colours on the same screen.
    ///
    /// Rules, in order:
    ///   1. Not in the roster → grey. We do not know which slot this member
    ///      occupies, and slot 0 is a LIE: it is some other member's colour, so
    ///      two people render identically. Grey already means "no reliable data"
    ///      in this palette and cannot collide with a real slot. It self-corrects
    ///      the moment the roster decrypts.
    ///   2. No fix, or a fix older than `staleThresholdMs` → grey. There is no
    ///      live dot on the map for this member, so no colour to match.
    ///   3. Otherwise the palette slot for their position in the roster.
    ///
    /// Position in the roster is deliberately kept as the key even though a hash
    /// of `userId` would be stable across loads: the Android app colours members
    /// by `MEMBER_COLORS[position % size]`, and a circle whose members see
    /// different colours on different platforms is worse than one whose colours
    /// shift when somebody joins.
    static func bubble(forUserId userId: String, in roster: [CircleMember], ageMs: Int64?) -> UIColor {
        guard let idx = roster.firstIndex(where: { $0.userId == userId }) else { return stale }
        guard let ageMs, ageMs <= staleThresholdMs else { return stale }
        return color(forIndex: idx)
    }

    /// A member's colour on a history trail: their roster slot, as on their
    /// marker, but without rule 2, since history is old by nature. Not in
    /// the roster → grey, as rule 1.
    static func trail(forUserId userId: String, in roster: [CircleMember]) -> UIColor {
        guard let idx = roster.firstIndex(where: { CanonicalId.same($0.userId, userId) }) else { return stale }
        return color(forIndex: idx)
    }

    /// Ink for the two-character initials sitting on `bubble`.
    ///
    /// White fails WCAG AA on every single colour in this palette — measured
    /// against the relative-luminance formula the rest of the app uses (see
    /// `A11yColors`):
    ///
    ///     Amber #FCD34D 1.44:1   Teal #5EEAD4 1.48:1   Emerald #4ADE80 1.74:1
    ///     Blue  #93C5FD 1.80:1   Pink #F9A8D4 1.81:1   Purple  #C4B5FD 1.85:1
    ///     Red   #FCA5A5 1.90:1   grey #9E9E9E 2.68:1   Indigo  #818CF8 2.98:1
    ///
    /// Near-black #1C1C1E clears 4.5:1 on all nine (5.70:1 on Indigo, the
    /// tightest, up to 11.80:1 on Amber).
    ///
    /// Chosen by luminance rather than hard-coded so a future palette entry
    /// dark enough to need white initials gets them. `MemberPaletteContrastTests`
    /// pins the whole palette at AA.
    static func ink(on bubble: UIColor) -> UIColor {
        let dark = UIColor(hex: "#1C1C1E") ?? .black
        return contrast(bubble, dark) >= contrast(bubble, .white) ? dark : .white
    }

    /// WCAG 2.x contrast ratio. Same formula as `A11yColors`' comments.
    static func contrast(_ a: UIColor, _ b: UIColor) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func relativeLuminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        // Resolve against the light appearance: these bubbles are a fixed
        // palette, not dynamic colours, so the trait makes no difference to
        // them — but `stale` and any future dynamic entry would otherwise
        // resolve unpredictably off the main thread.
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        func channel(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }
}

/// Member marker. 52pt colored circle, 3pt white border, two-character
/// bold initials (the ink is picked by contrast,
/// `MemberPalette.ink(on:)`), and an "age" label ("now" / "5m" / "2h")
/// in haloed white below the circle. Mirrors the Android app's
/// `getOrCreateMemberIcon` so cross-platform circles render
/// consistently.
final class MemberMarkerView: MLNAnnotationView {
    private let halo = CAShapeLayer()
    private let circle = CAShapeLayer()
    private let border = CAShapeLayer()
    private let initialsLabel = UILabel()
    private let sosPill = CAShapeLayer()
    /// Warning triangle in the pill: a glyph needs no translation.
    private let sosGlyph = UIImageView()
    private let ageLabel = UILabel()

    private static let dotSize: CGFloat = 52
    private static let agePadTop: CGFloat = 4
    private static let ageHeight: CGFloat = 16
    /// Wider than the dot so an "At <Place>" line fits; the label is
    /// centered and overflows the dot horizontally without changing the
    /// view bounds, so the marker's coordinate anchor never shifts.
    private static let labelWidth: CGFloat = 120
    /// "SOS" band under the initials, shown when this member has an active
    /// alert. Sized to sit where the age line normally starts; the age line
    /// slides below it (and past the view bounds, which don't clip — the
    /// "At <Place>" label already overflows horizontally for the same
    /// reason: growing the bounds would move the marker's anchor).
    private static let sosPadTop: CGFloat = 3
    private static let sosHeight: CGFloat = 17
    private static let sosWidth: CGFloat = 42
    /// How far the pulse reaches at full extent, from the centre of the dot.
    private static let haloRadius: CGFloat = 46

    /// How far the DOT's centre sits above the marker's anchor point.
    ///
    /// MapLibre centres an annotation view on its coordinate, but the dot is at
    /// the TOP of this view with the age / "At &lt;Place&gt;" labels hanging
    /// below — so the dot renders above the member's actual position by half the
    /// label stack. Anything reasoning about where the dot IS on screen (the
    /// place-pin occlusion test) has to subtract this, or it misjudges by 10pt.
    ///
    /// Constant because the bounds never change: the SOS pill and the shifted
    /// age line overflow them deliberately rather than growing the view, which
    /// would move the anchor.
    static let discRiseAboveAnchor: CGFloat = (dotSize + agePadTop + ageHeight) / 2 - dotSize / 2

    /// How close the dot's centre has to come to a place's pin, centre to centre
    /// on screen, before the pin counts as covered.
    ///
    /// Both are 52pt circles: they touch at 52 and are roughly half-covered at
    /// 26. 40 is where enough of the pin is behind the avatar that aiming at it
    /// stops being realistic — and being in points it scales with ZOOM, unlike
    /// the place's radius, which runs to 2 km and says nothing about what
    /// actually overlaps. Matches the Android app's `MemberMarkerGeometry`.
    static let occlusionThreshold: CGFloat = 40

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        commonInit()
    }
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }

    private func commonInit() {
        let total = Self.dotSize + Self.agePadTop + Self.ageHeight
        bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: total)
        backgroundColor = .clear
        clipsToBounds = false
        layer.zPosition = 1

        // One perceivable thing: who, how fresh, and where. MapLibre annotation
        // views are not accessibility elements by default and their child
        // labels are not exposed either, so without this NOTHING about a member
        // reaches VoiceOver — the map is a silent grey rectangle announced
        // "Map" with no people in it. It is also the only signal that
        // distinguishes a real member avatar from MapLibre's stock blue GPS
        // dot, which is what the first-run location test asserts on.
        isAccessibilityElement = true
        accessibilityIdentifier = "member-marker"
        accessibilityTraits = .staticText

        let dotRect = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
        let borderWidth: CGFloat = 3
        let inset = dotRect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)

        // Pulse, behind everything and centred on the DOT (not the view) so it
        // rings the avatar rather than the labels hanging below it. Hidden
        // unless this member has an active SOS.
        let dotCentre = CGPoint(x: dotRect.midX, y: dotRect.midY)
        // bounds + position rather than an arc drawn at an offset: the pulse
        // animates `transform.scale`, which scales about the layer's own anchor
        // point. A zero-bounds layer anchors at the view's origin, so the halo
        // would grow out of the top-left corner instead of out of the avatar.
        halo.bounds = CGRect(x: 0, y: 0, width: Self.haloRadius * 2, height: Self.haloRadius * 2)
        halo.position = dotCentre
        halo.path = UIBezierPath(ovalIn: halo.bounds).cgPath
        halo.fillColor = UIColor.systemRed.withAlphaComponent(0.28).cgColor
        halo.isHidden = true
        layer.addSublayer(halo)

        circle.path = UIBezierPath(ovalIn: inset).cgPath
        circle.fillColor = UIColor.systemBlue.cgColor
        circle.shadowColor = UIColor.black.cgColor
        circle.shadowOpacity = 0.25
        circle.shadowOffset = CGSize(width: 0, height: 1)
        circle.shadowRadius = 2
        layer.addSublayer(circle)

        border.path = UIBezierPath(ovalIn: inset).cgPath
        border.fillColor = UIColor.clear.cgColor
        border.strokeColor = UIColor.white.cgColor
        border.lineWidth = borderWidth
        layer.addSublayer(border)

        initialsLabel.frame = dotRect
        initialsLabel.font = .systemFont(ofSize: Self.dotSize * 0.38, weight: .bold)
        // Real colour is set in `configure`, where the resolved fill is
        // known — white fails WCAG AA on every bubble in the palette. See
        // `MemberPalette.ink(on:)`.
        initialsLabel.textColor = MemberPalette.ink(on: MemberPalette.colors[0])
        initialsLabel.textAlignment = .center
        addSubview(initialsLabel)

        // A warning triangle in a filled pill directly under the initials,
        // rather than a separate disc stamped over the avatar, so the person
        // asking for attention is still recognisable as themselves.
        let pillRect = CGRect(
            x: (Self.dotSize - Self.sosWidth) / 2,
            y: Self.dotSize + Self.sosPadTop,
            width: Self.sosWidth,
            height: Self.sosHeight
        )
        sosPill.path = UIBezierPath(roundedRect: pillRect, cornerRadius: Self.sosHeight / 2).cgPath
        sosPill.fillColor = UIColor.systemRed.cgColor
        sosPill.strokeColor = UIColor.white.cgColor
        sosPill.lineWidth = 1.5
        sosPill.isHidden = true
        layer.addSublayer(sosPill)

        sosGlyph.frame = pillRect.insetBy(dx: pillRect.width * 0.3, dy: 2)
        sosGlyph.image = UIImage(
            systemName: "exclamationmark.triangle.fill",
            withConfiguration: UIImage.SymbolConfiguration(weight: .heavy)
        )
        sosGlyph.tintColor = .white
        sosGlyph.contentMode = .scaleAspectFit
        sosGlyph.isHidden = true
        addSubview(sosGlyph)

        ageLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        ageLabel.textColor = .white
        ageLabel.textAlignment = .center
        ageLabel.adjustsFontSizeToFitWidth = true
        ageLabel.minimumScaleFactor = 0.7
        // Halo via shadow so age text reads against any map color.
        ageLabel.layer.shadowColor = UIColor.black.cgColor
        ageLabel.layer.shadowOpacity = 1.0
        ageLabel.layer.shadowOffset = .zero
        ageLabel.layer.shadowRadius = 2
        ageLabel.layer.masksToBounds = false
        addSubview(ageLabel)
    }

    /// What the marker shows: its initials, its caption (the age, or "At
    /// <Place>") and its fill. A marker already on the map is drawn again when
    /// this changes: its age moves on, it turns grey, it arrives somewhere, or
    /// its name opens.
    struct Appearance: Equatable {
        let initials: String
        let caption: String
        let fill: UIColor
    }

    static func appearance(displayName: String, ageMs: Int64, fillColor: UIColor, atPlaceName: String?,
                           isApproximate: Bool, sharingOff: Bool = false) -> Appearance {
        // The last location shared before real-time sharing went off:
        // grey, and the words their row and card say, never an age that
        // reads as a live position going stale.
        if sharingOff {
            return Appearance(initials: initials(from: displayName),
                              caption: SharingStatusCopy.rowLine(.off) ?? "", fill: MemberPalette.stale)
        }
        let isStale = ageMs > MemberPalette.staleThresholdMs
        // When the member is inside a saved place, show "At <Place>" in
        // place of the age — the occupied place's own pin is hidden, so
        // the avatar carries the place name. Never for an approximate member:
        // a place worked out from the centre of their area is finer than the
        // area they chose to share.
        let caption: String
        if let atPlaceName, !atPlaceName.isEmpty, !isApproximate {
            caption = "At \(atPlaceName)"
        } else {
            caption = formatRelativeAge(ageMs: ageMs)
        }
        return Appearance(initials: initials(from: displayName), caption: caption,
                          fill: isStale ? MemberPalette.stale : fillColor)
    }

    /// `appearance` of the member as the annotation holds it now.
    static func appearance(of member: MemberAnnotation) -> Appearance {
        appearance(displayName: member.displayName, ageMs: member.ageMs, fillColor: member.fillColor,
                   atPlaceName: member.atPlaceName, isApproximate: member.approximateMeters != nil,
                   sharingOff: member.sharingOff)
    }

    /// `configure` from the member as the annotation holds it now.
    func configure(member m: MemberAnnotation) {
        configure(displayName: m.displayName, ageMs: m.ageMs, fillColor: m.fillColor, isCurrentUser: m.isCurrentUser,
                  atPlaceName: m.atPlaceName, hasSOS: m.hasSOS, isApproximate: m.approximateMeters != nil,
                  sharingOff: m.sharingOff)
    }

    /// `appearance` of a fanned-out copy of a member.
    static func appearance(of fan: FanMemberAnnotation) -> Appearance {
        appearance(displayName: fan.displayName, ageMs: fan.ageMs, fillColor: fan.fillColor,
                   atPlaceName: fan.atPlaceName, isApproximate: fan.isApproximate, sharingOff: fan.sharingOff)
    }

    /// `configure` from a fanned-out copy of a member.
    func configure(fan f: FanMemberAnnotation) {
        configure(displayName: f.displayName, ageMs: f.ageMs, fillColor: f.fillColor, isCurrentUser: f.isCurrentUser,
                  atPlaceName: f.atPlaceName, hasSOS: f.hasSOS, isApproximate: f.isApproximate,
                  sharingOff: f.sharingOff)
    }

    func configure(
        displayName: String,
        ageMs: Int64,
        fillColor: UIColor,
        isCurrentUser: Bool,
        atPlaceName: String?,
        hasSOS: Bool = false,
        isApproximate: Bool = false,
        sharingOff: Bool = false
    ) {
        let shown = Self.appearance(displayName: displayName, ageMs: ageMs, fillColor: fillColor,
                                    atPlaceName: atPlaceName, isApproximate: isApproximate, sharingOff: sharingOff)
        initialsLabel.text = shown.initials
        circle.fillColor = shown.fill.cgColor
        // Ink follows the fill: a stale grey bubble and an Amber one need
        // different initials to stay legible, and white served neither.
        initialsLabel.textColor = MemberPalette.ink(on: shown.fill)
        ageLabel.text = shown.caption
        applySOS(hasSOS)

        accessibilityLabel = Self.spokenLabel(displayName: displayName, caption: ageLabel.text,
                                              hasSOS: hasSOS, isApproximate: isApproximate)
    }

    /// Spoken as one phrase, in the order the marker reads visually. The
    /// attention state leads: it is the first thing that should be heard,
    /// not a detail appended after someone's name.
    ///
    /// This is the ONLY text carrying that state — the pill holds a
    /// warning triangle with no label — so it has to say what the glyph
    /// means rather than name it. Likewise the area round an approximate
    /// member is only drawn, so the label says it.
    static func spokenLabel(displayName: String, caption: String?, hasSOS: Bool, isApproximate: Bool) -> String {
        [
            hasSOS ? "Needs attention" : nil,
            displayName,
            isApproximate ? ApproximateLocationCopy.spoken : nil,
            caption,
        ].compactMap { $0 }.joined(separator: ", ")
    }

    /// Show or hide the SOS marking. Explicitly two-sided: MapLibre recycles
    /// these views through a reuse pool, so a view that last rendered a member
    /// in trouble must be able to render an ordinary one.
    private func applySOS(_ hasSOS: Bool) {
        self.hasSOS = hasSOS
        halo.isHidden = !hasSOS
        sosPill.isHidden = !hasSOS
        sosGlyph.isHidden = !hasSOS
        // The age line moves out from under the pill when one is shown.
        let ageTop = Self.dotSize + (hasSOS ? Self.sosPadTop + Self.sosHeight : 0) + Self.agePadTop
        ageLabel.frame = CGRect(
            x: (Self.dotSize - Self.labelWidth) / 2,
            y: ageTop,
            width: Self.labelWidth,
            height: Self.ageHeight
        )
        // Above every other marker, so nothing standing next to the raiser can
        // paint over the emergency (member dots sit at 1, cluster badges at 2).
        layer.zPosition = hasSOS ? 10 : 1
        if hasSOS {
            startPulsing()
        } else {
            halo.removeAnimation(forKey: "sosPulse")
        }
    }

    private var hasSOS = false

    /// Urgent double-time pulse, matching the standalone SOS marker's, so both
    /// representations of an emergency beat the same way.
    private func startPulsing() {
        halo.removeAnimation(forKey: "sosPulse")
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.45
        scale.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.9
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        halo.add(group, forKey: "sosPulse")
    }

    /// UIKit strips animations from off-window layers and MapLibre recycles
    /// annotation views, so the pulse has to be re-armed when the view comes
    /// back on screen — same reason `SOSMarkerView` does it.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && hasSOS { startPulsing() }
    }

    /// 2-character uppercase initials. "Sam" → "S", "Sam Smith" → "SS".
    /// Empty / single-character names fall back to the first character
    /// or "?" so the marker is never blank.
    private static func initials(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        let parts = trimmed.split { $0.isWhitespace }
        if parts.count >= 2,
           let a = parts.first?.first,
           let b = parts.dropFirst().first?.first {
            return String([a, b]).uppercased()
        }
        return String(trimmed.prefix(1)).uppercased()
    }

    /// Shared with SOSMarkerView's caption, so the standalone marker's age and a
    /// member marker's age are formatted identically ("now" / "12m" / "2h").
    static func formatRelativeAge(ageMs: Int64) -> String {
        let sec = ageMs / 1_000
        let min = sec / 60
        let hr = min / 60
        let day = hr / 24
        switch true {
        case sec < 60: return "now"
        case min < 60: return "\(min)m"
        case hr < 24:  return "\(hr)h"
        case day < 365: return "\(day)d"
        default:       return "\(day / 365)y"
        }
    }
}

/// Cluster badge. A 40pt purple circle with a 3pt white border and a
/// white bold count centered inside, rendered in place of the
/// individual member avatars whenever they would visually overlap at
/// the current zoom (manual screen-space clustering — see
/// `ClusterAnnotation`). Same CAShapeLayer + UILabel construction as
/// `MemberMarkerView`, sized smaller and sitting at zPosition 2 so a
/// badge always stacks above the member dots it replaces. Mirrors
/// the Android app's cluster-count marker.
final class ClusterMarkerView: MLNAnnotationView {
    private let circle = CAShapeLayer()
    private let border = CAShapeLayer()
    private let countLabel = UILabel()

    private static let size: CGFloat = 40
    /// Brand purple — matches the Android app's cluster fill.
    private static let fill = UIColor(hex: "#6D4AFF") ?? .systemPurple

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        commonInit()
    }
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }

    private func commonInit() {
        bounds = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        backgroundColor = .clear
        // Above the member dots (zPosition 1) so a badge always wins
        // the stack against any avatar that happens to share its pixel.
        layer.zPosition = 2

        let dotRect = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        let borderWidth: CGFloat = 3
        let inset = dotRect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)

        circle.path = UIBezierPath(ovalIn: inset).cgPath
        circle.fillColor = Self.fill.cgColor
        circle.shadowColor = UIColor.black.cgColor
        circle.shadowOpacity = 0.25
        circle.shadowOffset = CGSize(width: 0, height: 1)
        circle.shadowRadius = 2
        layer.addSublayer(circle)

        border.path = UIBezierPath(ovalIn: inset).cgPath
        border.fillColor = UIColor.clear.cgColor
        border.strokeColor = UIColor.white.cgColor
        border.lineWidth = borderWidth
        layer.addSublayer(border)

        countLabel.frame = dotRect
        countLabel.font = .systemFont(ofSize: 15, weight: .bold)
        countLabel.textColor = .white
        countLabel.textAlignment = .center
        addSubview(countLabel)
    }

    /// Cap the displayed count at "99+" so a very large group never
    /// overflows the 40pt badge.
    func configure(count: Int) {
        countLabel.text = count <= 99 ? "\(count)" : "99+"
    }
}

/// Place marker. 52pt colored circle with the place's emoji centered
/// inside, white border (dashed for shared, solid for own). Mirrors
/// `getOrCreatePlaceIcon` in the Android app. The place name floats
/// underneath as a separate haloed label so it reads against any map
/// color without competing with the circle's background fill.
final class PlaceMarkerView: MLNAnnotationView {
    private let circle = CAShapeLayer()
    private let border = CAShapeLayer()
    private let symbolView = UIImageView()
    private let label = UILabel()

    private static let dotSize: CGFloat = 52

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        commonInit()
    }
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }

    private func commonInit() {
        let total = Self.dotSize + 4 + 16
        bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: total)
        backgroundColor = .clear

        let dotRect = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
        let borderWidth: CGFloat = 3
        let inset = dotRect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)

        circle.path = UIBezierPath(ovalIn: inset).cgPath
        circle.shadowColor = UIColor.black.cgColor
        circle.shadowOpacity = 0.25
        circle.shadowOffset = CGSize(width: 0, height: 1)
        circle.shadowRadius = 2
        layer.addSublayer(circle)

        border.path = UIBezierPath(ovalIn: inset).cgPath
        border.fillColor = UIColor.clear.cgColor
        border.strokeColor = UIColor.white.cgColor
        border.lineWidth = borderWidth
        layer.addSublayer(border)

        symbolView.frame = dotRect.insetBy(dx: Self.dotSize * 0.27, dy: Self.dotSize * 0.27)
        symbolView.contentMode = .scaleAspectFit
        symbolView.tintColor = .white
        addSubview(symbolView)

        label.frame = CGRect(x: -16, y: Self.dotSize + 4, width: Self.dotSize + 32, height: 16)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 1.0
        label.layer.shadowOffset = .zero
        label.layer.shadowRadius = 2
        label.layer.masksToBounds = false
        addSubview(label)
    }

    func configure(name: String, icon: String, hexColor: String, isShared: Bool) {
        label.text = name
        symbolView.image = UIImage(systemName: icon)
        circle.fillColor = (UIColor(hex: hexColor) ?? .systemBlue).cgColor
        // Dashed border for shared places, solid for own/in-circle —
        // matches the Android app's DashPathEffect on shared
        // markers.
        if isShared {
            border.lineDashPattern = [6, 4]
        } else {
            border.lineDashPattern = nil
        }
    }

    /// Toggle the place-name label visibility — driven by the map's
    /// zoom level (Coordinator updates this on region change). Matches
    /// the Android app's minZoom = 12 gate on the SymbolLayer,
    /// which hides the name at city/region zooms where the labels
    /// would just be noise and the icon-only marker is enough.
    func setLabelHidden(_ hidden: Bool) {
        label.isHidden = hidden
    }
}

/// Dropped-pin marker — orange mappin, anchored at the tip rather
/// than the center so it lands on the tapped coordinate exactly.
final class DroppedPinView: MLNAnnotationView {
    private let symbolView = UIImageView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        bounds = CGRect(x: 0, y: 0, width: 32, height: 40)
        backgroundColor = .clear
        symbolView.image = UIImage(systemName: "mappin.and.ellipse")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold))
        symbolView.tintColor = .systemOrange
        symbolView.frame = bounds
        symbolView.contentMode = .center
        addSubview(symbolView)
        centerOffset = CGVector(dx: 0, dy: -10)
    }
    required init?(coder aDecoder: NSCoder) { super.init(coder: aDecoder) }
}

/// Destination marker. 52pt creator-colored circle with a white flag
/// glyph and a haloed name label underneath — the same shape as
/// `PlaceMarkerView`, color-coded by creator like the member dots.
/// Mirrors the Android app's `updateDestinationMarkers`.
final class DestinationMarkerView: MLNAnnotationView {
    private let circle = CAShapeLayer()
    private let border = CAShapeLayer()
    private let symbolView = UIImageView()
    private let label = UILabel()

    private static let dotSize: CGFloat = 52

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        commonInit()
    }
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }

    private func commonInit() {
        let total = Self.dotSize + 4 + 16
        bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: total)
        backgroundColor = .clear
        // Between the member dot (zPosition 1) and the default place (0)
        // so a destination at the same coordinate stacks deterministically
        // and a member on top still wins the tap.
        layer.zPosition = 0.5

        let dotRect = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
        let borderWidth: CGFloat = 3
        let inset = dotRect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)

        circle.path = UIBezierPath(ovalIn: inset).cgPath
        circle.shadowColor = UIColor.black.cgColor
        circle.shadowOpacity = 0.25
        circle.shadowOffset = CGSize(width: 0, height: 1)
        circle.shadowRadius = 2
        layer.addSublayer(circle)

        border.path = UIBezierPath(ovalIn: inset).cgPath
        border.fillColor = UIColor.clear.cgColor
        border.strokeColor = UIColor.white.cgColor
        border.lineWidth = borderWidth
        layer.addSublayer(border)

        symbolView.frame = dotRect.insetBy(dx: Self.dotSize * 0.28, dy: Self.dotSize * 0.28)
        symbolView.contentMode = .scaleAspectFit
        symbolView.tintColor = .white
        symbolView.image = UIImage(systemName: "flag.fill")
        addSubview(symbolView)

        label.frame = CGRect(x: -16, y: Self.dotSize + 4, width: Self.dotSize + 32, height: 16)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 1.0
        label.layer.shadowOffset = .zero
        label.layer.shadowRadius = 2
        label.layer.masksToBounds = false
        addSubview(label)
    }

    func configure(name: String, fillColor: UIColor) {
        label.text = name
        circle.fillColor = fillColor.cgColor
    }

    func setLabelHidden(_ hidden: Bool) {
        label.isHidden = hidden
    }
}

/// An SOS shown as an AREA (the same on every platform, as an approximate
/// member is shown): its label at the area's centre, white on the alert's red
/// in a rounded box. No disc, no pulse, nothing that reads as an exact pin;
/// the area itself is the red `ApproximateAreaPolygon` under it. The label is
/// the alert's tap target, as the disc is.
final class SOSAreaLabelView: MLNAnnotationView {
    private let label = UILabel()
    private static let inset = UIEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        commonInit()
    }
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .systemRed
        layer.cornerRadius = 8
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 1.5
        layer.zPosition = 10
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        addSubview(label)
    }

    /// The label's lines, the box sized round them; MapLibre centres it on the
    /// area's centre.
    func setText(_ text: String) {
        label.text = text
        let fits = label.sizeThatFits(CGSize(width: 220, height: CGFloat.greatestFiniteMagnitude))
        let inset = Self.inset
        bounds = CGRect(x: 0, y: 0, width: ceil(fits.width) + inset.left + inset.right,
                        height: ceil(fits.height) + inset.top + inset.bottom)
        label.frame = bounds.inset(by: inset)
    }
}

/// A red disc with a white ring and a warning triangle across it, over a soft
/// red glow that keeps swelling outward and fading.
///
/// Deliberately not the member-marker shape — someone asking for attention
/// should not read as "one more person on the map" at a glance. `zPosition`
/// puts it above every other marker (member dots sit at 1): it is usually
/// raised by a member standing at the same coordinate, so without this their
/// own avatar covers their own marker.
final class SOSMarkerView: MLNAnnotationView {
    private let halo = CAShapeLayer()
    private let circle = CAShapeLayer()
    private let border = CAShapeLayer()
    private let glyph = UIImageView()
    private let caption = UILabel()

    private static let dotSize: CGFloat = 46
    private static let haloSize: CGFloat = 92

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        commonInit()
    }
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }

    private func commonInit() {
        bounds = CGRect(x: 0, y: 0, width: Self.haloSize, height: Self.haloSize)
        backgroundColor = .clear
        layer.zPosition = 10

        let center = CGPoint(x: Self.haloSize / 2, y: Self.haloSize / 2)

        halo.path = UIBezierPath(
            arcCenter: center, radius: Self.haloSize / 2,
            startAngle: 0, endAngle: .pi * 2, clockwise: true
        ).cgPath
        halo.fillColor = UIColor.systemRed.withAlphaComponent(0.28).cgColor
        layer.addSublayer(halo)

        let dotRect = CGRect(
            x: center.x - Self.dotSize / 2, y: center.y - Self.dotSize / 2,
            width: Self.dotSize, height: Self.dotSize
        )
        let borderWidth: CGFloat = 3
        let inset = dotRect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)

        circle.path = UIBezierPath(ovalIn: inset).cgPath
        circle.fillColor = UIColor.systemRed.cgColor
        circle.shadowColor = UIColor.black.cgColor
        circle.shadowOpacity = 0.3
        circle.shadowOffset = CGSize(width: 0, height: 1)
        circle.shadowRadius = 2
        layer.addSublayer(circle)

        border.path = UIBezierPath(ovalIn: inset).cgPath
        border.fillColor = UIColor.clear.cgColor
        border.strokeColor = UIColor.white.cgColor
        border.lineWidth = borderWidth
        layer.addSublayer(border)

        glyph.frame = dotRect.insetBy(dx: dotRect.width * 0.27, dy: dotRect.height * 0.27)
        glyph.image = UIImage(
            systemName: "exclamationmark.triangle.fill",
            withConfiguration: UIImage.SymbolConfiguration(weight: .heavy)
        )
        glyph.tintColor = .white
        glyph.contentMode = .scaleAspectFit
        addSubview(glyph)

        // Wider than the disc so the phrase fits; the label is centred and
        // overflows horizontally without changing the view's bounds, so the
        // marker's coordinate anchor does not shift (same trick MemberMarkerView
        // uses for its "At <Place>" line).
        caption.frame = CGRect(
            x: (Self.dotSize - 150) / 2,
            y: Self.dotSize + 3,
            width: 150,
            height: 15
        )
        caption.font = .systemFont(ofSize: 11, weight: .semibold)
        caption.textColor = .white
        caption.textAlignment = .center
        caption.adjustsFontSizeToFitWidth = true
        caption.minimumScaleFactor = 0.75
        // Halo via shadow so it reads against any basemap colour.
        caption.layer.shadowColor = UIColor.black.cgColor
        caption.layer.shadowOpacity = 1.0
        caption.layer.shadowRadius = 2.0
        caption.layer.shadowOffset = .zero
        addSubview(caption)

        startPulsing()
    }

    /// Set the "Sent from here · 12m" line. Empty hides it.
    func setCaption(_ text: String) {
        caption.text = text
        caption.isHidden = text.isEmpty
    }

    /// Urgent double-time pulse, so an SOS reads as an SOS. Re-armed in
    /// didMoveToWindow because UIKit strips animations from off-window layers
    /// and MapLibre recycles annotation views through its reuse pool.
    private func startPulsing() {
        halo.removeAnimation(forKey: "sosPulse")
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.45
        scale.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.9
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        halo.add(group, forKey: "sosPulse")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startPulsing() }
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((value & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(value & 0x0000FF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
