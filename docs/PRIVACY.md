# Privacy

The claim is that a document you translate never leaves your Mac. Every app
that handles private documents makes some version of that claim, and a reader
has no way to check any of them from the outside. So this one is built to be
checkable three ways.

## 1. Translating cannot make a request

Every engine that touches a document runs in this process or in macOS: Apple
Vision reads the page, Laesesalen's own vision-language model reads it again on
the Mac's GPU, and either that model or Apple's translates. None of them is a
network service. With the optional model server off — which is how the app
ships — translating a document opens no socket at all.

There is exactly one thing in the app that does reach the internet, and it is
not translation: **fetching a model's weights**, once, because you pressed a
button. That request asks a public host for a file by name. No part of any
document is in it, and it is written down in the ledger under its own heading
so it can never be confused with document traffic.

`SystemLanguageModel` is the on-device model. The Foundation Models framework
also offers `PrivateCloudComputeLanguageModel`, which sends the prompt to
Apple's servers, and the prompt here would be the reader's document. That name
is banned from `Sources` by a check that fails the build.

## 2. The only address the app can form is this machine

The optional model server exists so that a Mac without Apple Intelligence, or a
document a 3-billion-parameter model reads badly, is not a dead end. It is the
one part of the app that opens a connection, and it is shaped so that "point it
at my server" cannot become "point it at a server":

- **`LoopbackEndpoint`** can only be constructed from a loopback address. It
  classifies with the C resolver rather than by string prefix, so `127.1` and
  `0177.0.0.1` are accepted, `127.0.0.1.example.com` is not, and `localhost` is
  normalized to the literal rather than resolved — a hosts file cannot move it.
- **`PrivateSession`** accepts nothing but a `LoopbackEndpoint`, and it is the
  only type in the package that touches `URLSession`. Its configuration is
  ephemeral (no cookie jar, no cache, no credential store), proxies are
  explicitly disabled, and redirects are refused outright — a local server
  answering 302 must not be able to forward the body of the request, and the
  body of the request is your document.
- **No other target links a networking API.** `Scripts/check-privacy.sh` fails
  if one appears, so sending a page somewhere else would take a deliberate edit
  to `Package.swift` first. That includes `DocMLX`, which runs the app's own
  model: it may fetch weights through the Hub client and may not open a
  connection of its own.

## 3. The app keeps the receipts

The lock in the corner of the window opens a ledger of every connection the app
has opened this session: address, path, bytes each way, and outcome. With the
built-in models the ledger is empty and stays empty, which is a stronger
statement than any sentence in this file.

## What is written to disk

Model weights, if you asked for them, and nothing else but what you save.

Laesesalen's own vision model lives in
`~/Library/Application Support/Laesesalen/Models` — not in your Documents
folder, which is where the Hugging Face client puts downloads by default. The
engines panel has a button to delete it, and deleting that folder by hand does
the same thing. There is no library, no recents list, no cache, no
index, and no crash-recovery copy. The document is held for as long as it takes
to translate it and let go when you start another. Preferences store the shape
of your workflow — the output mode, whether to ask questions, standing
instructions, the server address if you set one — and never a document's
contents or its path.

Exports are self-contained. The HTML export contains no link, font, image, or
script from anywhere, so a translated page you open in a browser makes no
request either. That is checked too.

## What this does not protect you from

Worth being plain about:

- **Downloading a model is a download.** Laesesalen's own vision model comes
  from Hugging Face and macOS's translation model comes from Apple. Both are
  fetched once, on request, and neither carries any part of a document. The
  ledger records them as model downloads rather than as document traffic,
  which is the honest description and also the one that would make a real leak
  visible rather than lost in the noise.
- **The weights download is made by a library, not by this app.** MLX fetches
  them through Hugging Face's own Swift client. That client is where the
  request is actually made, so for that one line the ledger is repeating what
  the library reported rather than proving it — the app can prove where its
  own requests went, and it says so.
- **The optional model server is only as private as the server.** The app can
  only reach `127.0.0.1`, but what a program on your machine does with what it
  receives is that program's business. If you point Laesesalen at something on
  loopback that forwards elsewhere, the ledger will show the app's side of it
  and nothing more.
- **Apple Intelligence is Apple's.** The on-device model runs on your Mac and
  this app never invokes Private Cloud Compute, but the framework's own
  behaviour is Apple's to document, not this project's to promise.
- **A file you export is a file.** Once you save a translation, where it goes is
  up to you and to whatever else has access to that folder.
