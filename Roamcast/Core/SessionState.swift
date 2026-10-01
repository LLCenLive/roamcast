import Foundation

/// États d'une session (CDC §14).
/// IDLE → PREPARING → WALKING ⇄ DRONE_PREPARATION → DRONE → WALKING → ENDING → FINISHED
enum SessionState: String, Codable, Equatable, CaseIterable {
    case idle
    case preparing
    case walking
    case dronePreparation
    case drone
    case ending
    case finished

    /// Invariant central du produit : une fois à l'antenne, la connexion RTMP ne peut
    /// être fermée qu'en ENDING / FINISHED. Balade, préparation drone, drone = le live continue.
    var allowsRTMPClose: Bool {
        self == .ending || self == .finished || self == .idle || self == .preparing
    }

    /// Le live est-il censé être à l'antenne ?
    var isOnAir: Bool {
        switch self {
        case .walking, .dronePreparation, .drone: return true
        default: return false
        }
    }
}

enum SessionEvent: Equatable {
    case openSetup
    case goLive
    case requestDrone
    case cancelDrone
    case droneReady
    case backToWalk
    case stop
    case stopped
    case reset
}

enum SessionTransitionError: Error, Equatable {
    case invalid(from: SessionState, event: SessionEvent)
}

/// Machine à états pure : aucune dépendance iOS, entièrement testable.
struct SessionStateMachine {
    private(set) var state: SessionState = .idle

    init(state: SessionState = .idle) { self.state = state }

    static func next(from state: SessionState, on event: SessionEvent) -> SessionState? {
        switch (state, event) {
        case (.idle, .openSetup):                 return .preparing
        case (.preparing, .goLive):               return .walking
        case (.preparing, .reset):                return .idle
        case (.walking, .requestDrone):           return .dronePreparation
        case (.dronePreparation, .cancelDrone):   return .walking
        case (.dronePreparation, .droneReady):    return .drone
        case (.drone, .backToWalk):               return .walking
        // Perte du drone en vol : on revient à la balade, jamais à l'arrêt du live.
        case (.drone, .cancelDrone):              return .walking
        case (.walking, .stop),
             (.dronePreparation, .stop),
             (.drone, .stop):                     return .ending
        case (.ending, .stopped):                 return .finished
        case (.finished, .reset):                 return .idle
        default:                                  return nil
        }
    }

    @discardableResult
    mutating func send(_ event: SessionEvent) throws -> SessionState {
        guard let next = Self.next(from: state, on: event) else {
            throw SessionTransitionError.invalid(from: state, event: event)
        }
        state = next
        return next
    }
}
