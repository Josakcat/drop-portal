//
//  PortalEffect.swift
//  DropPortalCore
//
//  How a card crosses between the phone and the Mac. One setting drives both
//  sides: the Mac stores it, serves it in the page (`data-effect`) and sends it
//  over the peek socket, so the page switches live.
//

public enum PortalEffect: String, CaseIterable, Identifiable, Sendable {
    case portal, liquid, wormhole, beam, plane

    public static let `default` = PortalEffect.portal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .portal: "Portal light"
        case .liquid: "Liquid"
        case .wormhole: "Wormhole"
        case .beam: "Beam"
        case .plane: "Paper plane"
        }
    }

    /// A stored value: an effect's raw value, or anything older (the Fly,
    /// Fade and Pop landing animations) or unknown, which reads as Portal light.
    public init(stored: String?) {
        self = stored.flatMap(PortalEffect.init(rawValue:)) ?? .default
    }
}
