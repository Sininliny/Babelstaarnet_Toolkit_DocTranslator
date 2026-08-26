# How Laesesalen works

The pipeline and the design rules behind it. The [README](../README.md) covers
installing and using the app; [PRIVACY.md](PRIVACY.md) covers the guarantee.

## The pipeline

A page goes through seven stages. Everything is **per sentence**, and every
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

Babelstaarnet reached the same unit from the other end — it assembles a sentence
*across* wrapped lines, because bridging a single visual line gave readers
fragments that began after the subject and stopped before the verb. Its
`SentenceBoundary` is used here as it stands.

The unit is the sentence; the context is the document. Those are different
questions, and a pipeline that answers the first one well and does not ask the
second produces a document that is correct sentence by sentence and reads like
several translations stapled together. Stage 3 exists for the second question.

There is a third question underneath both, and it is the one with the sharpest
edge: some words in a document are not translated at all. They are *recalled*.
布洛芬 is ibuprofen — not by any operation on the characters, which spell out as
"buluofen", but because that is what the drug is called. A sentence-at-a-time
translator that does not know this writes a word that names no medicine, in an
English sentence that reads perfectly, on a prescription somebody is about to
act on. Stage 5 exists for that question.

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
   this role, in this order of preference: Laesesalen's own model, running in
   this process on the Mac's GPU through MLX; Apple's on-device model, where
   Apple Intelligence is available; or a model on a server you run.

   Carrying its own is what makes the second reader dependable. Apple's model
   is excellent and free, and whether a given Mac may use it is Apple's
   decision, not the reader's — a machine can report itself ineligible with no
   remedy the user can act on. A 4-bit Qwen vision model in the app's own
   address space is available on any Apple-silicon Mac, and it was trained on
   exactly the thing this app is pointed at: Chinese document images. How large
   a one is a question for the machine rather than a constant — see
   [The app's own models](#the-apps-own-models).

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
*is*: what kind of thing it is, what field it belongs to, what it concerns, the
situation it is part of, how it should sound, and up to eight recurring terms
with the rendering each will get throughout. That is `DocumentProfile`, and
every stage afterwards is handed it.

The background — two or three sentences on who the parties are to each other,
what has already happened, and what the document is meant to bring about — is
separate from the subject and does different work. The subject names the
document. The background is what a translator asks a client before starting,
and it is what makes a bare instruction on page six an instruction *about*
something.

The terms are the part that earns the call. 甲方 is "Party A" in a contract and
"the first party" in a news report. 执行 is "enforcement" in a court notice and
"execution" in a technical manual. 通知 is a "notice" from an authority and a
"notification" in software. A translator shown one sentence at a time will pick
a defensible rendering each time and pick differently on page seven than on
page one — and because every individual choice is correct, nothing downstream
flags it. Not the second translator, which is translating the same lone
sentence. Not the reviewing model, which is shown one block. Deciding once, in
advance, and handing the decision down is the only thing that fixes it.

The field is not a label for the interface. It decides what the things in the
document are *called*: a drug by its generic name or its brand name, a body by
its own English name or by a description of it, a statute by the title it is
published under or by a rendering of its characters. `DocumentField` carries
those conventions as instructions, and they go down with the rest of the
profile to every stage that only ever sees one block. A model that answers the
rest of the form and skips the field has usually said it anyway — "a discharge
summary" is medicine, "an enforcement notice" is law — so it is inferred rather
than left blank, because the blank is not a neutral default: it is a document
translated with no naming conventions at all.

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

### The page around a block

The profile is what the whole document knows. Underneath it is a smaller
question with the same shape: how much of the page *immediately* around a block
does that block need?

Both easy answers are wrong. Give every block everything — the sentence before,
the sentence after, the heading above — and two things happen, both of them
expensive. The prompt roughly triples on every block of every page, on a model
running on somebody's laptop at twenty seconds a page. And a small model handed
two sentences and asked for one translation will sometimes translate both, or
carry on from the context instead of translating the block. That failure does
not look like a failure: it produces fluent English of a sentence that *is* on
the page, in the wrong place, and every mechanical check downstream passes it.
Give every block nothing and 该方 becomes "the said party" one line after the
party was named.

So there is a floor and there is a widening. The floor is the English of the
line before — short, already in the target language, so it cannot be mistaken
for something to translate, and it is what keeps a recurring term rendered the
same way twenty sentences apart without anyone having written it down. Above
the floor, a block has to ask, and `AdaptiveContext` decides from three
properties of the block itself:

- **It is too short to carry its own context** — a heading, a cell, a label.
- **It points at something outside itself** — 该方, 上述, 前款.
- **It continues something** — it opens with 但是 or 因此, or the block before
  it did not end at a sentence stop.

What each of those buys is different, and that matters more than the signals
do. A reference backwards is answered by the sentence *before* it. A heading is
answered by the section *after* it: 执行 is "enforcement" over a court order and
"execution" over a build script, and nothing in the heading decides which. An
item in a list or a cell in a table is answered by the heading *above* it,
which may be on the previous page — a table that starts on page two has its
column headings on page two and its last row on page three, and the row is no
less under them for the page turn. Handing every block all three would cost the
same as handing it none and be worse than either.

Two details are load-bearing. The heading is carried in **English**, because it
has already been translated by the time the rows under it are reached, and
context in the language being written cannot be mistaken for something to
translate. And the cues are matched as substrings — in a language written
without spaces there is nothing else to match on — so the language pack also
lists the words that *contain* a cue and are not one: 应该 means "ought to" and
contains 该, and without that list the rule fires on every obligation in the
document, which on a court notice is every sentence. A rule that fires on
everything is the rule that was not written.

What each block was given is recorded on it and shown in the side-by-side
export. A block translated on its own and a block translated with its heading
above it are two different questions asked of the model, and a reader checking
a doubtful line is entitled to know which one was asked.

**And where the context turns out to have been the problem, the block is
translated again without it.** Measured, because the effect is not one anybody
would have predicted. The five blocks of a court notice, put to the 3B five
times each:

| what the block was shown | came back untranslated |
| --- | --- |
| nothing | 0 of 25 |
| the English of the line before | 5 of 25 |
| both halves of the line before | 4 of 25 |
| both halves, differently worded | 4 of 25 |

Every failure was the same block — a numbered item that is mostly figures —
and it failed with *anything* in front of it, in every wording tried. The
model does not mistranslate it; it copies it back. Whatever the mechanism,
context in front of a block that is nearly all digits is enough to tip a small
model from translating into copying, and the wording of the request has
nothing to do with it.

The rule this licenses is deliberately narrow. Deciding in advance which
blocks are "too numeric for context" would be fitting a rule to one
measurement: the item that failed is 44% digits and the one below it, which
never failed, is 38%. So nothing is decided in advance. `TextIntegrity`
already detects this exact failure — it is the check for a paragraph handed
back untranslated — and detection is the trigger: a block that came back as
its own source, *and* was given context, is translated once more with nothing
around it, and the second answer is kept only if it did better. The second
call is paid only where the first one demonstrably failed. On the fixture page
that is five untranslated blocks reduced to one, for nine seconds on a
forty-second run.

`swift run --traits MLXEngine Checks --prompt-probe` re-runs the table above
against whatever model is configured, which is how to redo the measurement
rather than trust it after a model change.

### 4. Ask, if it matters

Before anything is translated, the app may ask up to three questions about the
document — from the same survey the profile was built from, so a question
raised only by page nine is still asked before page one is translated — but
only where the answer would change the English. This stage
exists because some translation errors cannot be caught afterwards at all: a
translator that does not know whether 对方 is the other party to a contract or
the other side in a dispute will pick one, write a fluent sentence around it,
and every downstream check will pass.

One of the questions is the app's own rather than a model's: if reading the
document did not establish what field it belongs to, the reader is asked, first
and ahead of anything a model thought of. No other answer changes as many
words, and a model that has just failed to say what field a document is from is
not the right participant to decide whether that matters. The options say what
choosing them commits the translator to — "Medicine — drugs by their generic
name, doses copied exactly" — because "Medicine" and "Law" are labels someone
could pick between without learning anything about what happens next. The
answer is taken back into the profile, not merely passed on as guidance, so the
stage that looks the names up is told the field the reader just named.

The reader is the only participant who knows what the document is. "I'm not
sure" is always offered and always last, because forcing a guess converts the
app's uncertainty into the reader's decision, which is worse than not asking.

### 5. Look the names up

Everything else in this pipeline improves a translation. This stage prevents a
particular kind of nonsense that no amount of improving reaches.

布洛芬 is ibuprofen. Not because the characters say so — they say "bù luò fēn",
which is how Chinese borrowed the English word to begin with — but because that
is what the drug is called. A model translating one line of a prescription at a
time has two ways to answer: recall the name, or spell the characters out. The
second produces "Buluofen", and every check in this app approves of it. The
reading was right. The doses match. The length is plausible. The reviewing
model, shown that block alone, agrees the English says what the Chinese says.
The only participant who could catch it is the reader — who came here because
they cannot read the source.

So `NameResolver` asks, in a call whose only job is that question, what the
things in this document are already called: a medicine's international
nonproprietary name, a company's registered name, an institution's own name for
itself, a statute's official title, a standard's designation, a place's usual
spelling. It runs after the profile, so the lookup happens in a field rather
than in the abstract, and after the reader has answered, because what they said
outranks what the app worked out.

Two rules do most of the work:

- **`UNKNOWN` is an answer.** A model that is not certain is told to say so,
  and the name is then transliterated where the reader can see it and question
  it. An invented name is the worst output this app can produce: it is fluent,
  specific, passes every mechanical check, and is the one thing the reader
  cannot verify.
- **A name "resolved" to its own Pinyin is dropped.** It has recorded the
  mistake as though it were the answer, and it would then suppress the
  mechanical check in every block it appears in — the one case where a wrong
  entry is worse than no entry.

What comes back goes to the block that contains it, with the *reason* attached:
a translator told that 布洛芬 is "ibuprofen" because that is the drug's generic
name has been given a rule it can apply to the next drug on the list, which no
entry covers. The reviewer is told the same thing, because a reviewer that has
not been told what the drug is called will read "Buluofen", find it consistent
with a source it can see says 布洛芬, and approve it.

The app ships no dictionary — no drug list, no company register, no table of
statutes. It could not carry one that stayed current and it would still miss
the document in front of it. What it does instead is ask the question
separately, in a field, of a model that has been told to admit ignorance.

The names it settled are shown in the window while the run goes, and printed in
full in the export's provenance. A name is the one decision in this pipeline
that a reader can check without reading a word of the source: they know what
they are taking.

### 6. Translate

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

### 7. Check it

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
  doing it, any pinned term the translation ignored, any rendering that
  disagrees with what the document settled on in stage 3, and any name that
  came back spelled out in Pinyin.

That last one is the check with no model equivalent anywhere in the pipeline. A
block that renames a party is fluent, faithful to its own sentence, and wrong
only in relation to the other forty blocks — which is exactly the comparison
neither the second translator nor the reviewer is in a position to make. It is
raised as a caution rather than a failure, and the distinction is deliberate: a
pinned term is the reader's instruction and the profile is the app's own
reading, so it is entitled to be flagged and not to be obeyed. Where the reader
has pinned the same term, the reader wins and the app says nothing.

The Pinyin check is the mechanical half of stage 5, and it works without any
model having recalled anything: the app spells the source out itself, one
syllable per character, and looks for the result in the English as a whole
word. If the English contains a word that is exactly what the Chinese sounds
like, the translator transliterated where it should have looked up. Three
characters at least, and matched as a whole word, is what keeps it quiet — a
private person's name is transliterated and should be, and "Wang Xiaoming" is
written in parts, so no window of three characters spells out as one word
there. It is raised as a caution, because some names really are their own
romanization: 阿里巴巴 is "Alibaba". Where the document or the reader has
already settled that name, nothing is reported at all.

A blocking mechanical finding caps the confidence below the top band and cannot
be outvoted, because everything else going right is exactly the condition under
which a dropped figure goes unnoticed.

One rule in the number check is worth naming: a month is a digit in Chinese and
a word in English. 3月 becomes "March", so a month position whose name appears
in the English is not a dropped figure. Without that, every dated document
would be flagged.

## The app's own models

The second reader and the text roles can both be filled by models the app
fetches and runs on this machine's GPU. Three things about that are decisions
rather than defaults.

**How large a model is a question for the machine.** `MachineCapability` asks
this Mac what it is — Apple silicon or not, how much unified memory, how much
free disk — and `LocalModelCatalogue` offers the largest model whose *working
set* fits in three quarters of that memory. Three quarters because macOS caps
what a process may wire for the GPU at around that share, and because the
window, the page images and everything else the reader has open live in the
rest. Working set rather than download size because weights are the floor: on
top of them sit the key-value cache, the activations, and a page image expanded
into several thousand tokens, which is the largest single request this app
makes of a model.

The consequence is a range instead of a default: a 2B on an eight-gigabyte
laptop, a 3B or 4B on twelve, a 7B on sixteen, the 32B on sixty-four. A single
default is wrong in both directions, and the two wrongs are not symmetrical.
Too small wastes a machine. Too large does not run slowly — it swaps, and a
page that should take twenty seconds takes four minutes, which does not look
like a bad recommendation but like a broken app. So the arithmetic is
deliberately generous, and the reader can override it.

**A second model is the exception.** One model does the reading *and* the text
work by default, because a vision-language model is a language model with an
image encoder bolted on: the text roles cost nothing extra, where a second
model is a second download, a second few gigabytes resident, and two models
swapping in and out of memory on every block. That trade only turns over on a
Mac that can hold both at once — and there it is worth taking, because a
dedicated text model translates and reviews appreciably better than a vision
model of the same size. So the app offers one exactly where both fit, and
nowhere else.

A text model brings one hazard a vision model does not: several of the good
ones reason before they answer. That is wrong for this app twice over. The
reasoning is *output*, so left in it is what gets drawn onto the page in place
of the translation; and a model that reasons for two hundred tokens before each
of several hundred blocks has multiplied the length of the run. So the
catalogue records the switch each model's own chat template accepts for turning
it off, the agent puts that switch in the instructions rather than the prompt —
where it could end up in the text being translated — and
`AgentPrompts.stripReasoning` removes the block from the answer whatever the
template did with the request. The token budget is raised to match, because a
one-word answer with an eight-token budget and a model that reasons first is a
model that never answers, and an adjudicator that silently stops adjudicating.

**Everything installed can be uninstalled.** `LocalModelStorage` is ordinary
file handling in `DocCore` rather than in the MLX target, and that placement is
the point: the default build has no MLX in it, and it must still be able to
list what an earlier build downloaded and give the disk space back. It finds
two kinds of dead weight — a model the reader tried and moved on from, and one
this version of the app no longer offers at all, which is the kind no other
screen would ever mention again. An identifier is validated as exactly two path
components before it is turned into a path, because that path is the argument
to a deletion and the identifier came out of a preferences file.

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
ranges, the sentence terminators, the expansion ratio, the reading
normalization, and how the script is spelled out in Latin letters when it is
spelled out rather than translated. Adding Japanese is adding a target beside `LanguageChinese`, not
editing the pipeline.

What a pack must not carry is the *order* of the pipeline. Which reader leads
and what happens when they disagree encode correctness constraints, not tuning
preferences, so they stay in the pipeline where they cannot be reconfigured per
language.

The romanization is in the pack for the same reason as everything else in it:
布洛芬 spells out as "buluofen" in Pinyin whatever anyone would prefer. Above
the pack, the pipeline knows only that some scripts can be spelled out and that
spelling one out is not translating it — which is enough for the prompt to name
the thing the model must not do, and enough for the mechanical check to catch
it when the model does it anyway.

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
make app        # dist/Laesesalen.app
make install    # build and put it in /Applications

make build-mlx  # the same, with the app's own vision model
make app-mlx
```

`swift run --traits MLXEngine Checks --vlm-probe` re-runs the image-size
comparison above against whatever model is configured, and `--prompt-probe`
re-runs the context comparison. Both exist because a prompt and an image size
are not code and cannot be checked like code: the way they fail is that a
model quietly does something slightly different, which no assertion in this
project would notice. Redoing the measurement is the only way to know, and
after a model change it is the first thing to redo.

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
- **The app knows no names of its own.** Every lookup in stage 5 is a model
  recalling something, and a model that does not know is told to say so rather
  than guess — so a name nobody recalled is transliterated and flagged, not
  invented. The flag is a caution rather than a failure because the check
  cannot tell a name that genuinely is its own romanization from one that
  should have been looked up.
- **A block never sees the page after it across a page break.** The sentence
  after the last block on a page has not been read yet, and reading ahead to
  give one translator one more line would double what a scan costs. The
  backward context does cross page breaks; the forward context does not.
- **The measured numbers in this document were taken with the 3B.** The image
  size table, the figure-fidelity count and the similarity threshold in the
  checks are all that model on that fixture. A larger reader should do better
  and is not claimed to until `--vlm-probe` has been run against it.
- **How large a model a Mac can hold is estimated, not measured.** The rule is
  weights plus forty per cent plus three gigabytes, against three quarters of
  unified memory. It is deliberately generous, so on a machine doing nothing
  else a larger model than the app offers will often run.
