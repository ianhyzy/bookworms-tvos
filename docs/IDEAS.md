# Feature ideas

This file lists proposed features. None of them is implemented unless [views](../VIEWS.md) or [data sources](../DATASOURCES.md) describe it. When a feature ships, document it there and remove it here.

Each idea notes the data it needs. "Synced" means the Hardcover library or social sync already fetches it; "New query" means a new request or field, which must keep library access read-only and stay out of browsing and focus handling.

## Current reads

- **Progress on the Book Wall.** The wall's ribbon currently marks focus. Proposed: current reads always carry a ribbon whose length shows progress, and focus uses a different cue. Alternative: a brass spine tab shows the percentage. Data: synced.

## Reading goal worm

A small worm crawls along the My Shelf board from left to right as you progress toward your yearly reading goal. For example, it shows 18 of 30 books at 60% of the shelf width. The worm stays static between syncs and respects Reduce Motion. Data: new query for the Hardcover reading goal; books finished this year are synced.

## Split-flap board

A 3D split-flap display, like a Vestaboard, spells out the titles of your most recently read books. Each title flips in letter by letter, and the board suits ambient mode. Reduce Motion replaces the flips with a fade. Data: synced.

## Series

Book details show the series and its books. Still open: a series shelf that groups your series with progress, such as "3 of 7 read", and the next unread book.

## Authors

- Select an author in book details to see their bio, photo, and the other books in your library.
- Show the author's other works you haven't read.

Data: library books by author are synced; bios, photos, and other works need a new query.

## Year in Review

- An all-time view and a comparison of two years.
- Your ratings compared with community ratings, such as "you rated this ★5, the community ★3.2."
- A fullscreen "Wrapped" slideshow at the end of the year, which could also play in ambient mode.

Data: synced.

## Reader leaderboard

Rank readers by books and pages read this year. Include only people you follow, or only mutuals. Data: followed readers' libraries are synced; mutuals need a new query for followers.

## Other ideas

- **Taste match:** a rating-overlap score for each followed reader, used to sort the reader picker.
- **Want to read shelf** with a **Pick for me** button.
- **Ambient overlays,** such as a clock or date.
- **Multiple Apple TV users:** follow the tvOS user profile so each household member sees their own Hardcover shelf.

## Delighters

Small, book-specific easter eggs for readers who know the book.

### Ground rules

- Match a book by its author and its title, ignoring subtitles and edition notes, as `HouseOfLeaves.isNovel` does, because each edition has its own Hardcover book ID. Never match by title alone, so similarly named books don't trigger the wrong effect.
- Keep each effect subtle and static by default. Respect Reduce Motion, and keep text legible and VoiceOver labels unchanged.
- Use only synced data and bundled assets. A delighter must not add network calls, Keychain reads, or work during focus movement.

### Ideas from the library

#### House of Leaves (Mark Z. Danielewski)

Extend the blue "house" that [views](../VIEWS.md) describe to the word in other languages, as the book does. Optionally strike through "minotaur" in red.

#### Infinite Jest (David Foster Wallace)

Place a small, unlabeled cartridge somewhere on the details page or shelf, matching the book's description of the Entertainment. Selecting it shows nothing at all. Other options:

- Show finished dates in Subsidized Time, such as Year of the Depend Adult Undergarment.
- Turn long descriptions into numbered endnotes.

#### Leech (Hiron Ennes)

Draw black tendrils that creep in from the corners of the book details page.

#### Annihilation, Authority, and Acceptance (Jeff VanderMeer)

Grow faint moss or fungal lettering along the edges of the details page, as on the tower wall in Area X.

#### Piranesi (Susanna Clarke)

Write dates in Piranesi's journal style, such as "the Fifth Day of the Twelfth Month in the Year the Albatross came to the South-Western Halls," using the reader's own read date.

#### There Is No Antimemetics Division (qntm)

Show the cover blank the first time the details page opens. The title fades whenever the book loses focus, as though the reader keeps forgetting it.

#### The Raw Shark Texts (Steven Hall)

A shark made of typed letters sits still in the description, like a frame of the book's flip-book sequence. When the reader turns the effect on, it swims slowly through the text; Reduce Motion keeps it still.

#### Dungeon Crawler Carl (Matt Dinniman)

Show a snarky achievement banner, in the dungeon AI's voice, when the reader opens a book in the series or finishes another one.

#### Murderbot Diaries (Martha Wells)

Add a SecUnit status line to the details page, for example how many *Sanctuary Moon* episodes the reader could have watched instead, estimated from the book's page count.

#### Discworld (Terry Pratchett)

- The Luggage walks along the shelf on its many small legs.
- Going Postal shows a clacks tower that sends "GNU Terry Pratchett," the real tribute message.
- Text that Death says appears in small caps.

#### The Night Circus (Erin Morgenstern)

After sunset, the book's details page turns black and white, like the circus that opens only at nightfall.

#### The Three-Body Problem (Cixin Liu)

A faint countdown flickers over the cover, then disappears.

#### Fahrenheit 451 (Ray Bradbury)

Singe the edges of the cover and let a few embers drift up from the bottom of the details page.

#### Nineteen Eighty-Four (George Orwell)

Show a stat on the details page that reads "2 + 2 = 5."

#### Kafka on the Shore (Haruki Murakami)

Rain a few small fish down the details page.

#### Dhalgren (Samuel R. Delany)

Cut the description off mid-sentence and wrap it back to the beginning, as the novel's last line completes its first.

#### Slaughterhouse-Five (Kurt Vonnegut)

List the reader's read dates out of order, because Billy Pilgrim is unstuck in time. Add "So it goes." under any list of finished books.

#### The Memory Police (Yoko Ogawa)

Each time the reader returns to the book, one small detail disappears from the details page, such as a genre tag or the page count.

#### Horrorstör (Grady Hendrix)

Lay out the details page like a flat-pack furniture catalog, with a product name and a dimension diagram.

#### The Expanse (James S. A. Corey)

Thin, glowing blue protomolecule filaments spread across the cover.

#### Dune (Frank Herbert)

A low sand ripple travels under the shelf board, like a sandworm passing beneath.

#### Gideon the Ninth (Tamsyn Muir)

Paint skull makeup on the reviewers' profile photos and give one of them sunglasses.

#### This Is How You Lose the Time War (Amal El-Mohtar and Max Gladstone)

Show reviews as sealed letters that ask to be burned before reading.

#### Children of Time (Adrian Tchaikovsky)

Spin a fine spider web in one corner of the details page.

#### It (Stephen King)

A red balloon drifts up past the edge of the screen.

#### Watchmen (Alan Moore and Dave Gibbons)

Add a smiley badge with a blood spatter, and a Doomsday Clock that reads a few minutes to midnight.

#### Project Hail Mary (Andy Weir)

Pair the reader's rating with a line of Eridian musical chords.
