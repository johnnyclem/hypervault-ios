/// The SF Symbol for each concept, one per concept (handoff 2.7), so the same idea draws the same glyph wherever it
/// appears. Decorative symbols next to text are hidden from VoiceOver by the view that draws them; a `Label` already
/// does that.
enum HVSymbol {
    // The dock.
    static let home = "house"
    static let chat = "bubble.left"
    static let memory = "brain"
    static let you = "person"

    // The panes of You.
    static let general = "gearshape"
    static let vault = "lock"
    static let agentKeys = "key"
    static let models = "sparkles"
    static let domain = "globe"
    static let appearance = "paintpalette"
    static let importData = "square.and.arrow.down"

    // Moving about.
    static let add = "plus"
    static let open = "chevron.right"
    static let fold = "chevron.down"
    static let back = "chevron.backward"

    // What a vault entry is.
    static let login = "globe"
    static let card = "creditcard"
    static let contact = "person"
    static let address = "house"
    static let key = "key"

    // What can be done to one.
    static let delete = "trash"
    static let copy = "doc.on.doc"
    static let copied = "checkmark"
    static let close = "xmark"
}
