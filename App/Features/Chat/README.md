# Chat

Chats, rooms (group chats with several of your models), your own
models, on-device chat and reading replies aloud. Home is the chats: `ChatRootView` is the root of the Home tab.

- `ChatRootView`: Home, a "Chats | Rooms" list screen (the switch sits under the title). Its one toolbar has the avatar, Keep
  (pushes the canvas, `Route.keep`), New chat / New room and More (Yours, Models in Settings, Tools, Import). Both lists are
  inset cards on paper (`hvListRow`), grouped by when they last moved.
- `HomeStarterView`: what the Chats half is when the server says there are no chats (`ChatListModel.showsStarter`: never off a
  cached copy or a refresh that failed): Start a chat, Keep something, the starter prompt to copy, and the first-run card
  that asks for an agent's key.
- `ConversationScreen`: the thread. `Conversation/` holds its model, composer,
  options sheet, bubbles, markdown and read-aloud.
- Under a reply: copy, keep (a page or note in Yours), save as a memory (a memory tagged `chat`, titled by
  `ChatShare.title`, the web's rule), thumbs and read aloud. In the options sheet, Recall is a switch until
  there is more than one memory branch; then it is a picker of Off and the branches, sent as `recall_branch`.
- `RoomScreen`: a room. `Rooms/` holds the list, creation, members and the model. `ChatRoomModel` has two workers that
  do not wait for each other: the follower (`ChatRoomFollower`, Kit) reads the room from the server while the screen is up
  and the app is in front (every 1.5 to 5 seconds while a round moves, every 20 otherwise) and is what puts messages on
  screen; the driver (`ChatRoomDriver`, Kit) pushes the queue along one turn per request, and stops when the screen goes,
  leaving the rest queued behind a Continue card. What only a device can check is in `docs/DEVICE_TEST_PLAN.md`
  ("A room, on a device").
- `Models/`: connect, edit and disconnect your own models (`/api/backends`). Every field has its
  label above it (`HVLabeledField`).
- Colour follows the model, not its place in a list: `ChatAgentTone` (in `ChatSupport`) gives Claude,
  GPT, Gemini, Grok and the rest one colour each on the Models screen, on an imported chat's pill and
  in a room. A second member of the same model in one room takes a neighbouring tone.
- `OnDevice/`: availability, the Foundation Models adapter, and models on the
  person's own network. The turn itself (context, generate, save, the offline
  outbox) is `OnDeviceChat` in the Kit; a model on this iPhone and a model on
  the home network are two `ChatModelProvider`s behind it.
- What a small model is told is not what the server sent. The server's system prompt is written for
  large models ("answer from the excerpts, and if they fall short, say what is covered"), and Apple's
  on-device model followed that to the letter: it answered about the excerpts, or handed one back. So
  `OnDeviceBrief` (Kit) rewrites it: a short directive that makes the question the job, then only the
  notes that bear on it, as optional background, inside the model's window. `OnDeviceReplyScreen`
  reads the first words of the reply; if it is a non-answer or a copy of a note, the question is asked
  once more with no notes. The grounding chips under a reply list only what the model was shown.

## Left out on purpose

- Renaming a chat: `PATCH /api/conversations/[id]` takes only `visibility` and
  `truth_ledgers`, so there is nothing to call.
- Truth ledger pinning per chat (`truth_ledgers`): the Kit sends it; no picker yet.
- Photos in a message: the composer's photo button (a connected model only: a model on this phone or on
  the home network is sent words) picks up to three. `ChatImagePrep` shrinks each to a JPEG under 800 KB
  before it is sent as base64 in `images` (`POST /api/chat`). The server keeps a picture's name, type and size,
  not the picture, so the bubble shows thumbnails while the chat is open and "2 photos" after it is reopened.
  A message still needs words. The camera is not offered yet; the photo picker already lists the camera roll
  and screenshots.
- Importing a `.jsx` or `.pdf` from the composer (the web has it): Import and Keep
  already cover that on the phone.
- Shared chat pages (`/c/<slug>`) open in Safari from the share sheet.
- Connected models (`/api/backends`) are called by the server, which refuses
  addresses that only mean something on one network. So a home Ollama is added
  under "On your network" instead: the phone calls it directly (no key, no tools)
  and the turn is saved to the vault afterwards.
