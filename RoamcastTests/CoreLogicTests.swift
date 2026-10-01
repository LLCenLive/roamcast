import XCTest
@testable import Roamcast

final class SessionStateTests: XCTestCase {
    /// Scénario de validation du MVP (CDC §19), sans matériel.
    func testMVPScenario() throws {
        var m = SessionStateMachine()
        let path: [(SessionEvent, SessionState)] = [
            (.openSetup, .preparing), (.goLive, .walking), (.requestDrone, .dronePreparation),
            (.droneReady, .drone), (.backToWalk, .walking), (.stop, .ending), (.stopped, .finished),
        ]
        for (event, expected) in path {
            XCTAssertEqual(try m.send(event), expected)
        }
    }

    /// Invariant : aucun état « à l'antenne » n'autorise la fermeture du RTMP.
    func testOnAirStatesNeverAllowRTMPClose() {
        for s in SessionState.allCases where s.isOnAir {
            XCTAssertFalse(s.allowsRTMPClose, "\(s) ne doit pas pouvoir fermer le RTMP")
        }
    }

    /// Seul `.stop` mène à ENDING depuis un état à l'antenne.
    func testOnlyStopLeadsToEnding() {
        let events: [SessionEvent] = [.openSetup, .goLive, .requestDrone, .cancelDrone, .droneReady, .backToWalk, .stop, .stopped, .reset]
        for s in SessionState.allCases where s.isOnAir {
            for e in events where SessionStateMachine.next(from: s, on: e) == .ending {
                XCTAssertEqual(e, .stop)
            }
        }
    }

    func testDroneLossFallsBackToWalking() throws {
        var m = SessionStateMachine(state: .drone)
        XCTAssertEqual(try m.send(.cancelDrone), .walking)
    }

    func testInvalidTransitionThrows() {
        var m = SessionStateMachine(state: .walking)
        XCTAssertThrowsError(try m.send(.droneReady))
    }
}

final class DuckerTests: XCTestCase {
    func testVoiceDucksThenReleases() {
        var d = Ducker(settings: DuckingSettings(enabled: true, reductionDB: -12, releaseSeconds: 1))
        // Voix pendant 0,5 s → atteint -12 dB
        for _ in 0..<50 { _ = d.process(micLevelDB: -20, dt: 0.01) }
        XCTAssertEqual(d.currentGainDB, -12, accuracy: 0.01)
        // Silence court (< hold) → reste baissé
        for _ in 0..<30 { _ = d.process(micLevelDB: -70, dt: 0.01) }
        XCTAssertEqual(d.currentGainDB, -12, accuracy: 0.01)
        // Silence long → remonte progressivement jusqu'à 0
        for _ in 0..<200 { _ = d.process(micLevelDB: -70, dt: 0.01) }
        XCTAssertEqual(d.currentGainDB, 0, accuracy: 0.01)
    }

    func testDisabledIsUnity() {
        var d = Ducker(settings: DuckingSettings(enabled: false))
        XCTAssertEqual(d.process(micLevelDB: 0, dt: 0.01), 1)
    }
}

final class BitrateTests: XCTestCase {
    func testDecreasesOnCongestionAndRespectsFloor() {
        var c = AdaptiveBitrateController(start: 4_500_000, min: 800_000, max: 5_000_000)
        for _ in 0..<20 {
            _ = c.update(.init(sentBitsPerSecond: 500_000, queuedBytes: 2_000_000, publisherReportedCongestion: true))
        }
        XCTAssertEqual(c.target, 800_000)
    }

    func testRaisesSlowlyAndCapsAtMax() {
        var c = AdaptiveBitrateController(start: 3_000_000, min: 800_000, max: 5_000_000)
        var raises = 0
        for _ in 0..<300 {
            if case .increase = c.update(.init(sentBitsPerSecond: c.target, queuedBytes: 0, publisherReportedCongestion: false)) { raises += 1 }
        }
        XCTAssertEqual(c.target, 5_000_000)
        XCTAssertEqual(raises, 8)
    }
}

final class PrivacyTests: XCTestCase {
    func testNearbyPointsSharePublicValue() {
        let a = LocationPrivacy.approximateLabel(latitude: 43.6512, longitude: 3.3601)
        let b = LocationPrivacy.approximateLabel(latitude: 43.6588, longitude: 3.3690)
        XCTAssertEqual(a, b)
    }

    func testZonePrefersAreaOfInterest() {
        XCTAssertEqual(LocationPrivacy.zoneLabel(areaOfInterest: "Lac du Salagou", locality: "Clermont-l'Hérault", adminArea: "Occitanie"),
                       "Lac du Salagou")
    }

    func testTagRules() {
        var tags: [String] = []
        tags = TwitchTagRules.add("Outdoor", to: tags)
        tags = TwitchTagRules.add("outdoor", to: tags)      // doublon
        tags = TwitchTagRules.add("Vol drone", to: tags)    // espace retiré
        XCTAssertEqual(tags, ["Outdoor", "Voldrone"])
    }

    func testChatParsing() {
        let line = "@color=#9146FF;display-name=Lucas;emotes= :lucas!lucas@lucas.tmi.twitch.tv PRIVMSG #llcenlive :salut : ça va ?"
        let m = TwitchChat.parsePrivmsg(line)
        XCTAssertEqual(m?.author, "Lucas")
        XCTAssertEqual(m?.text, "salut : ça va ?")
        XCTAssertEqual(m?.color, "#9146FF")
    }
}
