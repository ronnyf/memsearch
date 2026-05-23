This is a small preamble before the first heading.
It has two short lines, well above the meaningful-content threshold.

# Top-Level Title

Short body for the top-level section.

## Heading-Only Section

## Section With Comment

<!-- internal note: drop me from embedding only -->
Body text after a stripped comment. Still meaningful.

## Large Paragraph Section

Paragraph one is a deliberately long block of prose intended to push the
running buffer past the configured maximum chunk size of 1500 characters.
It rambles on at length about chunking, paragraph boundaries, and the way
the splitter prefers a clean blank-line break before falling back to a
forced line-boundary split. We pad with filler so the byte count grows
predictably across renderings: alpha bravo charlie delta echo foxtrot
golf hotel india juliet kilo lima mike november oscar papa quebec romeo
sierra tango uniform victor whiskey xray yankee zulu. The phonetic
alphabet adds entropy without changing semantics, which keeps the test
deterministic while still mirroring realistic prose. Continuing further:
the chunker should detect that this paragraph alone is below the limit
yet, when combined with the next paragraph, it crosses the threshold
exactly at the blank-line break — which is the boundary the algorithm
prefers above all others. A nice test of the paragraph-priority path.

Paragraph two carries on the same idea but with different filler so the
SHA-256 of the resulting chunk is distinct from paragraph one's hash.
We add more phonetic words to push past 1500 chars total: alpha bravo
charlie delta echo foxtrot golf hotel india juliet kilo lima mike
november oscar papa quebec romeo sierra tango uniform victor whiskey
xray yankee zulu, and once more for good measure: alpha bravo charlie
delta echo foxtrot golf hotel india juliet kilo lima mike november
oscar papa quebec romeo sierra tango. The combined section now exceeds
the chunk size, forcing the splitter into action.

Paragraph three is a short closer that should ride the overlap window.

### Nested Subsection

Body of a level-three heading. Helps verify nested levels track properly.

## Closing Section

Final body. Single line, well under the threshold.
