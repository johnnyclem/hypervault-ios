# Chat

The fourth tab: chats, rooms (group chats with several of your models), your own
models, on-device chat and reading replies aloud.

- `ChatRootView`: "Chats | Rooms" list screen; Models is the toolbar button.
- `ConversationScreen`: the thread. `Conversation/` holds its model, composer,
  options sheet, bubbles, markdown and read-aloud.
- `RoomScreen`: a room. `Rooms/` holds the list, creation, members and the model.
- `Models/`: connect, edit and disconnect your own models (`/api/backends`).
- `OnDevice/`: availability, the Foundation Models adapter, and models on the
  person's own network. The turn itself (context, generate, save, the offline
  outbox) is `OnDeviceChat` in the Kit; a model on this iPhone and a model on
  the home network are two `ChatModelProvider`s behind it.

## Left out on purpose

- Renaming a chat: `PATCH /api/conversations/[id]` takes only `visibility` and
  `truth_ledgers`, so there is nothing to call.
- Memory branches in the recall switch (`recall_branch`): the Kit sends it, the
  composer only has the on/off switch until memory branches have a screen.
- Truth ledger pinning per chat (`truth_ledgers`): the Kit sends it; no picker yet.
- Importing a `.jsx` or `.pdf` from the composer (the web has it): Import and Keep
  already cover that on the phone.
- Shared chat pages (`/c/<slug>`) open in Safari from the share sheet.
- Connected models (`/api/backends`) are called by the server, which refuses
  addresses that only mean something on one network. So a home Ollama is added
  under "On your network" instead: the phone calls it directly (no key, no tools)
  and the turn is saved to the vault afterwards.
