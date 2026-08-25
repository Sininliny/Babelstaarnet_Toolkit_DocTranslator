# How Læsesalen works

The pipeline and the design rules behind it. The [README](../README.md) covers
installing and using the app; [PRIVACY.md](PRIVACY.md) covers the guarantee.

## The pipeline

A page goes through six stages. Everything is **per sentence**, and every
sentence is translated against the whole document.

That unit is not an aesthetic choice, and getting it wrong broke the app once
already. A recognizer and a vision-language model do not divide a page the same
way: on a court notice with even line spacing, Apple Vision returned two blocks
— spacing is all it has to go on — while the model returned twenty-four, one
per printed line. Nothing can usefully compare two readings that disagree by a
factor of twelve about what a block is. The alignment degenerated, the model's
blocks matched nothing, they were adopted as text only it had seen, and the app
translated the reader that invents while the recognizer's reading of the same
words sat beside them unused at 0.99 similarity — the safety property inverted
exactly.

Cut both readings at sentence stops and they land on the same units. A sentence
is also the right unit for everything else: it is what a translator needs to
see at once, what a confidence score is worth attaching to, and small enough
that a person checking a flagged block can find it on the page.

Babelstårnet reached the same unit from the other end — it assembles a sentence
*across* wrapped lines, because bridging a single visual line gave readers
fragments that began after the subject and stopped before the verb. Its
`SentenceBoundary` is used here as it stands.

The unit is the sentence; the context is the document. Those are different
questions, and a pipeline that answers the first one well and does not ask the
second produces a document that is correct sentence by sentence and reads like
several translations stapled together. Stage 3 exists for the second question.

### 1. Read it, twice

Three readers, in a fixed order of authority:

1. **The PDF's own text layer**, where the file has one. This is not a
   recognition at all: a born-digital PDF contains the exact characters that
   were typeset. Where it exists it settles the block with no model involved,
   so a Word export costs no adjudication calls.
2. **Apple Vision**, at its accurate level, always. Vision's fast level does
   not recognize Chinese at all, and on other scripts it has been measured to
   drop diacritics while reporting unchanged confidence — a silent corruption
   no routing gate can detect. Speed is not worth a character that changes the
   word.
3. **A vision-language model** looking at the same page image. Three can fill
   this role, in this order of preference: Læsesalen's own model, running in
   this process on the Mac's GPU through MLX; Apple's on-device model, where
   Apple Intelligence is available; or a model on a server you run.

   Carrying its own is what makes the second reader dependable. Apple's model
   is excellent and free, and whether a given Mac may use it is Apple's
   decision, not the reader's — a machine can report itself ineligible with no
   remedy the user can act on. A 4-bit Qwen2.5-VL in the app's own address
   space is available on any Apple-silicon Mac, and it was trained on exactly
   the thing this app is pointed at: Chinese document images.

The two recognizing readers matter because their mistakes are of different
kinds. Vision reads glyph shapes and knows nothing about what the sentence
says, so it confuses 未 and 末. A language model reads the way a person skimming
does, so it does not — but it will quietly smooth a smudged clause into
something plausible, which Vision never will. Two readers whose failures
overlapped would agree on the same errors and their agreement would mean
nothing.

Colour preparation is a **retry**, never a first pass: a contrast pass tuned
hard enough to rescue a grey scan can wreck a clean one, and running it second
means it can only ever add readings.

### 2. Settle what it says

Lines become sentences first. A line continues the one above it when three
things agree: the gap is no wider than a line, the two share a column, and the
type is the same size. The third is the one that keeps a heading out of the
paragraph beneath it, where the first two alone would have accepted it. The
resulting run is then cut at sentence stops, and each sentence keeps the part
of the page it was printed on — including its share of a line it shares with
its neighbour, so two sentences on one line do not both erase it in the
layout-preserving export.

What counts as a stop comes from the language pack. Chinese needed one rule the
algorithm had never had to state: **full-width stops stand alone.** 。 is
followed immediately by the next sentence, and a space there would be a
typesetting error — so the algorithm's requirement of whitespace after a stop,
which is right for every language it was written for, finds no stops at all on
a Chinese page. The ASCII period keeps the requirement, because in Chinese text
it is nearly always a decimal point or part of a URL.

The recognizer's sentences have positions on the page; the model's have none.
So the two are matched by a sequence alignment on the text itself, with gaps
allowed on both sides and up to eight blocks on either side allowed to match
one on the other.

### What the model actually does, measured

Worth stating in numbers, because every rule in the next section is a
consequence of it. A rendered court notice — twelve lines of 30 px Chinese,
with a case number, an ID number and five money figures — read by Qwen2.5-VL
3B at greedy decode, fitted into 1024 px:

```
北京市朝阳区人民法院执行通知书          ← right
案号：（2024）京01执12345号             ← printed 京0105执12345号
被执行人：王明                          ← printed 王小明
一、支付货款人民币58000元及利息2340元    ← printed 580000元 and 23400元
二、支付违约金人民币4900元               ← printed 46000元
```

Eight of fourteen figures survived. A money figure lost a zero — a factor of
ten — and a name lost a character, and two whole lines were dropped. None of
it *looks* wrong: the Chinese is fluent, the register is right, and the
document reads exactly like a correct transcription of some court notice.

That is the failure this app is built around. It is not a bad model; it is
what a language model does when it reads. It also gets things a character
recognizer cannot: layout, reading order, a smudged character that only makes
sense one way. So it is kept as the second reader and never trusted as the
first.

Two rules follow directly, and both are enforced rather than requested:

**A disagreement that is only about figures never reaches a model.** If two
readings are identical once the digits are removed, the recognizer's numbers
win without a vote — it cannot invent a figure, and this model demonstrably
can.

**Image size is not a tuning preference.** The same model, page and decode,
fitted into different boxes: 512 px produced a *different document* (a civil
judgment, with a case number and a legal representative that are nowhere on
the page); 768 px repeated the title eight times; 1024 and 1280 both read the
page at 0.70 similarity. The failures at small sizes do not look like
failures. `MLXVisionReader.fitInto` carries the table.

Where the readings differ, a model chooses between them — and **only** chooses.
It is never asked to write a corrected version. A model allowed to correct a
disputed line will sometimes produce a fluent sentence that neither reader saw
and that is not on the page, and nothing downstream can catch that: a
hallucinated source sentence translates perfectly, passes every check, and
reads better than the truth. A chooser can be wrong, but only ever about
something that was actually printed.

Two asymmetries follow from the same reasoning:

- **A failed or absent adjudicator keeps the recognizer's reading**, because
  the recognizer is the reader that cannot invent text.
- **Text only the language model reported is kept, but marked** as the app's
  least trustworthy output, and it is left out of the layout-preserving export
  entirely — it has no measured place on the page to be drawn in.

### 3. Read the document

Before a word of it is translated, one model call establishes what the document
*is*: what kind of thing it is, what it concerns, how it should sound, and up
to eight recurring terms with the rendering each will get throughout. That is
`DocumentProfile`, and every stage afterwards is handed it.

The terms are the part that earns the call. 甲方 is "Party A" in a contract and
"the first party" in a news report. 执行 is "enforcement" in a court notice and
"execution" in a technical manual. 通知 is a "notice" from an authority and a
"notification" in software. A translator shown one sentence at a time will pick
a defensible rendering each time and pick differently on page seven than on
page one — and because every individual choice is correct, nothing downstream
flags it. Not the second translator, which is translating the same lone
sentence. Not the reviewing model, which is shown one block. Deciding once, in
advance, and handing the decision down is the only thing that fixes it.

**What it reads is a sample from across the document, not the front of it.**
Profiling from page one means profiling from a cover sheet, a letterhead, or a
case number — a contract states its parties on page one and defines its terms
on page three, and a judgment says what was decided at the end. So
`DocumentSurvey` spans the document, and what that costs depends on the file:

- **A PDF that carries its own text** costs nothing. The text is already in the
  file, so up to twelve pages of it are sampled, spread across the document.
- **A scan or a photograph** has to be recognized, so the survey is rationed to
  two extra pages beyond the one already read — chosen for spread, ending on
  the last page — and only with a reader quick enough to be worth it. Vision is
  half a second a page; the vision model is closer to twenty, and a survey that
  costs a minute has stopped being a survey.

Neither path reads the whole of a long document and neither claims to. What
both produce is a sample taken across it rather than off the front.

Two things follow from having a profile at all. A profile is something to
follow, so — exactly like a non-empty brief — it puts the instruction-following
translator in the lead whatever the speed preference says; a dedicated
translation model cannot be told anything. And the profile is shown in the
window *while the work is running*, because a wrong reading of what the
document is becomes a wrong assumption in every block, and the reader is the
only participant who can see that it is wrong.

Alongside the profile, each block is also given the sentence before it and the
English that sentence was translated into — across page breaks, not just within
a page. The English half is what keeps a recurring term rendered the same way
twenty sentences apart without anyone having written it down.

### 4. Ask, if it matters

Before anything is translated, the app may ask up to three questions about the
document — from the same survey the profile was built from, so a question
raised only by page nine is still asked before page one is translated — but
only where the answer would change the English. This stage
exists because some translation errors cannot be caught afterwards at all: a
translator that does not know whether 对方 is the other party to a contract or
the other side in a dispute will pick one, write a fluent sentence around it,
and every downstream check will pass.

The reader is the only participant who knows what the document is. "I'm not
sure" is always offered and always last, because forcing a guess converts the
app's uncertainty into the reader's decision, which is worse than not asking.

### 5. Translate

Two kinds of translator, and they are not interchangeable:

- **Apple's Translation framework** is a dedicated translation model: fast,
  consistent, and completely unable to take an instruction.
- **A language model** is slower and less consistent, and it is the only one of
  the two that can be told "keep the names in Chinese".

Whichever leads, the other gives a second opinion where it is available, and
two engines with no shared machinery producing the same English is evidence in
a way that one engine asked twice is not. A non-empty brief always puts the
instruction-following translator in the lead, whatever the speed preference
says — otherwise choosing "fastest" would silently discard everything the
reader asked for.

### 6. Check it

Three independent checks, and the third is the one that earns its place:

- **The second translator's answer**, compared with the first.
- **A reviewing model**, which reads the source and the draft together and may
  rewrite. This is what catches meaning: a dropped negation, an obligation
  turned into a permission.
- **`TextIntegrity`**, which is mechanical and catches what a reviewing model
  reliably does not — it is another language model with the same blind spots,
  and it will approve a fluent paragraph whose figures changed. Dropped or
  invented numbers, source script left untranslated, text handed back
  unchanged, repetition loops, a model answering about the task instead of
  doing it, any pinned term the translation ignored, and any rendering that
  disagrees with what the document settled on in stage 3.

That last one is the check with no model equivalent anywhere in the pipeline. A
block that renames a party is fluent, faithful to its own sentence, and wrong
only in relation to the other forty blocks — which is exactly the comparison
neither the second translator nor the reviewer is in a position to make. It is
raised as a caution rather than a failure, and the distinction is deliberate: a
pinned term is the reader's instruction and the profile is the app's own
reading, so it is entitled to be flagged and not to be obeyed. Where the reader
has pinned the same term, the reader wins and the app says nothing.

A blocking mechanical finding caps the confidence below the top band and cannot
be outvoted, because everything else going right is exactly the condition under
which a dropped figure goes unnoticed.

One rule in the number check is worth naming: a month is a digit in Chinese and
a word in English. 3月 becomes "March", so a month position whose name appears
in the English is not a dropped figure. Without that, every dated document
would be flagged.

## Confidence

Every block carries a score and, more importantly, the reasons behind it. The
reasons are what a reader can act on; 0.62 is not. The scoring is in one file
so it can be argued with, and two rules shape it: a blocking mechanical finding
outranks everything, and a block nobody checked is not a confident block —
`agreement` is `nil` rather than `1` when only one reader saw it, because "the
readers disagreed completely" and "nobody checked" call for different things
from the person reading the result.

## The three outputs

The pipeline is identical for all three; only what is written out differs.

**The same document, in English** draws the translation back onto the page it
came from. The background, stamps, photographs, rules and layout are the
original pixels; each translated block has a patch painted in a background
colour sampled from that block, with the English set in the sampled ink
colour. Colours are measured with a histogram rather than an average, because
averaging black text on white paper gives grey — the one colour that is
neither. Text that would not fit even at the minimum size overruns the box
downward rather than being clipped: a translation that overflows can be read,
and one that is silently cut cannot.

Two things are never translated, and on a form they are most of the page.
Page numbers and running heads, as before — and any block with none of the
source script in it. A results table is mostly figures: `68.4`, `0-450`,
`mg/L`, `CFU/mL`. Handed to a translator they do not come back unchanged —
`4` comes back `Four` and `mg/L` comes back `Mg/l` — and because this export
replaces any block whose English differs from its source, a correct figure
printed on the original page is painted over with a worse one. The figures are
the point of a results table.

The size is settled for a *run of type* rather than for a block. Fitted one at
a time, every block on a page can be individually correct and the page still
wrong: a heading shrunk to a caption because its English ran long, one row of
a table at twice the size of the row under it because two words fell into a
wide cell. Nothing on a page set that way is a mistake and none of it can be
read at a glance, which is the failure a form makes obvious and a letter
hides. So blocks are grouped by the height of the lines they were printed on —
the only surviving record of the original type size, and why the reconciler
carries a line count — and each group is set at one size. A block may be
smaller than its run because its English will not fit at that size; it may
never be larger because it happens to have room. Nothing that is not a heading
is set much larger than the page's ordinary type however tall its box is,
because a box far taller than everything around it is not large type — it is
two rows the reader handed back as one block. A heading, for this purpose, is
a block with its lines to itself: the classifier reads a one-word cell
measured slightly taller than the row above it as a heading, which on a form
is half the unit column, and set as one it comes out bold and larger in the
middle of a table.

What a block is allowed to use is the box the Chinese filled plus the empty
paper beside it, stopping at the nearest thing printed on its own lines and at
the edge of its column: the empty half of a two-column form is not empty
paper. What gets *erased* is smaller again — the original text and the English
replacing it, and nothing else. Erasing everything a block was allowed is what
takes the rule between two columns off the page. And the page is erased once
and written on afterwards, rather than a block at a time, because one row's
patch reaches into the next and the row that disappears would be one that was
already right.

**Just the text** is the words in reading order and nothing else — no
provenance header, no confidence marks, no markup to strip.

**Side by side** shows both languages with the app's working: what each reader
saw, how the block was settled, the first draft where the reviewer rewrote it,
and every finding.

## Language packs

No capability module names a language. Simplified Chinese is a value —
`SourceLanguage` — handed in at the composition root, and it carries the script
ranges, the sentence terminators, the expansion ratio, and the reading
normalization. Adding Japanese is adding a target beside `LanguageChinese`, not
editing the pipeline.

What a pack must not carry is the *order* of the pipeline. Which reader leads
and what happens when they disagree encode correctness constraints, not tuning
preferences, so they stay in the pipeline where they cannot be reconfigured per
language.

The normalization is the least obvious and most load-bearing part of the
Chinese pack. Vision returns Chinese with spaces scattered between glyphs and a
vision model returns none; left alone, that difference makes two identical
readings look like a 40% disagreement and sends every block on every page to
the adjudicator for nothing. A space between two Chinese characters is removed;
a space beside a Latin letter or digit is kept, because there it is a real word
boundary.

## Building and checking

```bash
make build      # the package
make test       # the privacy check, then the whole suite
make app        # dist/Læsesalen.app
make install    # build and put it in /Applications

make build-mlx  # the same, with the app's own vision model
make app-mlx
```

`swift run --traits MLXEngine Checks --vlm-probe` re-runs the image-size
comparison above against whatever model is configured, which is how to redo
the measurement rather than trust this table after a model change.

The MLX engine is a build-time option rather than a dependency because of what
building it takes: MLX compiles Metal kernels, and the `metal` compiler ships
with Xcode rather than with the Command Line Tools. The package declares an
`MLXEngine` trait, `DocMLX`'s sources are behind `#if MLXEngine`, and the
default build is the app without it — so a checkout still builds on a machine
that has only the tools, which is the same reason the interface is written on
`ObservableObject`.

The checks are an executable target rather than a test target. `swift test`
cannot run on a machine with only the Command Line Tools: the Swift Testing
library is a framework that ships with Xcode, so the bundle builds and then
fails to load. `swift run Checks` needs none of that.

The same constraint explains why the app is built on `ObservableObject` rather
than `@Observable` and `@State`. `@State` is a macro in the current SDK and its
plugin ships with Xcode; a project that uses it cannot be built from a plain
checkout with the tools alone.

## Known limits

- **Vertical Chinese text is not handled.** The layout assembler assumes
  horizontal lines and a left-to-right reading order within a column.
- **The layout-preserving export patches, it does not inpaint.** A block of
  text over a photograph or a gradient gets a flat patch of the sampled
  background colour. On solid backgrounds — which is most documents — it is
  invisible; on a photograph it is a visible rectangle.
- **More than two columns** are read as one. The gutter detector finds a single
  gutter.
- **A dense form can be assembled into overlapping blocks.** Where the cells of
  two adjacent rows are close enough to read as one run of text, the assembler
  joins them, and the block it produces covers rows that other blocks also
  claim. Nothing is lost — every block is still translated and still drawn —
  but in the layout-preserving export the two print over each other, and in a
  table that is where it shows.
- **Handwriting** is out of scope for Vision's Chinese recognition and will
  read badly or not at all.
- **The document profile is built from a sample, not the whole document.** A
  document that changes character partway through — a contract with an
  unrelated technical annex — is profiled from the parts the survey saw, and
  the annex is translated as though it were still the contract. The profile is
  shown in the window while the run is going so this is visible rather than
  silent, and an instruction in the brief overrides it.
