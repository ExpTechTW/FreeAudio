/// The outputs that play while global multi-output is on: the main one, which is the system's default device, and
/// the extra ones that get a copy of it.
enum MultiOutput {
    struct Selection: Equatable {
        var main: String
        var extras: [String]
    }

    /// What checking or unchecking an output in the panel does. An extra is added or removed. Unchecking the main
    /// output hands its place to the first connected extra, and the last output playing can't be unchecked (`nil`).
    /// Extras that aren't connected stay checked, so they play again when they're back.
    static func toggle(_ uid: String, in selection: Selection, connected: Set<String>) -> Selection? {
        if uid == selection.main {
            guard let next = selection.extras.first(where: { $0 != uid && connected.contains($0) }) else { return nil }
            return Selection(main: next, extras: selection.extras.filter { $0 != next && $0 != uid })
        }
        if selection.extras.contains(uid) {
            return Selection(main: selection.main, extras: selection.extras.filter { $0 != uid })
        }
        return Selection(main: selection.main, extras: selection.extras + [uid])
    }
}
