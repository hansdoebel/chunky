# Citations in Typst (APA 7, IU Zitierleitfaden)

Chunky exports a bibliography the Typst compiler can load, plus a cite you can paste at the point of use. The style is APA 7 as adapted by the IU Internationale Hochschule Allgemeiner Zitierleitfaden (Stand 01.10.2025). The deviations below were checked against Anhang C of that guide.

The style file is `Chunky/Resources/iu-apa7.csl`. Export CSL from Retrieval or the collection browser writes that same file. Hayagriva (`.yml`) and BibLaTeX (`.bib`) use one stable key: the cite key from Zotero or BibTeX when the chunk has one, otherwise author, year, and DOI.

Printed `page_labels` are used first, and only in the cite supplement. The PDF page index is used only when the chunk has no printed label. A single page is `S. 12`. A range is `S. 12–14`. The bibliography entry does not repeat that chunk page. A label is written as Typst text, so a character such as `#` cannot start code.

## Typst document

```typst
#set text(lang: "de")

Die Studie beschreibt den Zusammenhang
#cite(<lovelace2020>, supplement: [S. 12]).
Ein längerer Beleg steht bei
#cite(<lovelace2020>, supplement: [S. 12–14]).

#bibliography("refs.yml", style: "iu-apa7.csl")
```

`refs.yml` is the Hayagriva export. `iu-apa7.csl` sits next to the Typst file. A BibLaTeX `.bib` can replace the `.yml`:

```typst
#bibliography("refs.bib", style: "iu-apa7.csl")
```

## What the style changes from APA 7

Anhang C of the IU guide is the source for each row.

| Topic | IU Zitierleitfaden | How the export encodes it |
| --- | --- | --- |
| Page on an indirect citation of a specific place | Required, for example `S. 12` | Every Typst cite with a known page includes `supplement: [S. …]`. The CSL locator term is `S.` |
| Retrieval date on web sources | Never | The style has no `accessed` date |
| Date | German, for example 11. Januar 2024. An American date from a reference manager is also accepted by the guide | `default-locale` is `de-DE`, with German month names |
| Punctuation before `&` | No comma. A comma from a reference manager is also accepted | `delimiter-precedes-last` is `never` |
| Fixed terms | Hrsg., Kap., Aufl., S., Abs., Vorab-Onlinepublikation, zitiert nach, n.d. | Those terms are in the German locale. A journal article with neither pages nor a volume is marked Vorab-Onlinepublikation |
| Original year in the short cite | Only the year of the edition being used, not `2006/2024` | The citation layout prints `issued` and does not print `original-date` |
| Name particles such as von, van, and de | May be treated as part of the surname for sorting, or ignored under the usual German practice | `demote-non-dropping-particle` is `never`, so the particle stays with the family name |

The guide also has rules for German legal materials, figures, and presentations. Those are outside this export.
