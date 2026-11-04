/// The SF Symbol for each concept, one per concept (handoff 2.7), so the same idea draws the same glyph wherever it
/// appears. Decorative symbols next to text are hidden from VoiceOver by the view that draws them; a `Label` already
/// does that.
enum HVSymbol {
    // The dock.
    static let home = "house"
    /// Projects: a stack of boards. Not the folder (that is the Library's) and not the `point.3` family (that is Memory's, and
    /// `TabSymbolQuiet` finds the Memory tab's button by it).
    static let projects = "square.stack.3d.up"
    /// The memory graph. The iconography guide names the family `point.3.connected`; this is the symbol that draws it.
    static let memory = "point.3.connected.trianglepath.dotted"
    static let mail = "envelope"
    /// A conversation: the chat rows and the Memory answers draw it. (It is no longer a tab's glyph.)
    static let chat = "bubble.left"

    // The panes of Settings.
    static let general = "gearshape"
    static let vault = "lock"
    static let agentKeys = "key"
    /// Models is the chip, as it is in Chat: one glyph for the concept, and no sparkle for AI anywhere.
    static let models = model
    static let domain = "globe"
    static let appearance = "paintpalette"
    static let importData = "square.and.arrow.down"

    // Moving about.
    static let add = "plus"
    static let open = "chevron.right"
    static let fold = "chevron.down"
    static let back = "chevron.backward"
    static let selected = "checkmark"

    // What a vault entry is.
    static let login = "globe"
    static let card = "creditcard"
    static let contact = "person"
    static let address = "house"
    static let key = "key"

    // The model, and what is done with its reply. Chat, the Memory answers and the Home thread draw these.
    /// A model, wherever it runs or whoever made it. Where the model runs (this phone, this Mac) has glyphs of its own.
    static let model = "cpu"
    /// An agent, as opposed to the model behind it: the key it signs in with, as Agent keys and the Truth signers draw it. A task
    /// it holds, a page it wrote and a memory it left are marked with this and not with the chip, which is only ever a model.
    static let agent = agentKeys
    /// Keep a reply: the tray that takes a thing in.
    static let keep = "tray.and.arrow.down"
    /// Save a reply as a memory: the glyph of the memory graph.
    static let saveMemory = memory
    /// Read a reply aloud.
    static let speak = "speaker.wave.2"

    // What can be done to one.
    static let delete = "trash"
    static let copy = "doc.on.doc"
    static let copied = "checkmark"
    static let close = "xmark"
}
