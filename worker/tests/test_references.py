"""Reference lists, in-text links, and a mocked GROBID document."""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2] / "Chunky" / "Resources" / "Scripts"
sys.path.insert(0, str(SCRIPTS))

from references import (  # noqa: E402
    attach_references,
    cited_in_text,
    parse_reference_list,
    references_from_grobid,
    section_text,
)


IEEE = """
[1] A. Smith and B. Jones, "A useful title," Real Journal, 2021, doi: 10.1000/abc.
[2] C. Lee, "Another title," Proc. Conf., 2020.
"""

APA = """
Smith, A. (2021). A useful title. Real Journal.
Jones, B., & Lee, C. (2020). Another title. Proc. Conf.
"""

GROBID = """
<listBibl>
  <biblStruct>
    <analytic>
      <title>Confirmed title</title>
      <author><persName><forename>Ada</forename><surname>Lovelace</surname></persName></author>
    </analytic>
    <monogr>
      <title>Real Journal</title>
      <imprint><date when="2021"/></imprint>
    </monogr>
    <idno type="DOI">10.1000/xyz</idno>
  </biblStruct>
</listBibl>
"""


def test_ieee_and_apa_lists_keep_title_and_year():
    ieee, warnings = parse_reference_list(IEEE)
    assert warnings == []
    assert ieee[0]["title"] == "A useful title"
    assert ieee[0]["year"] == 2021
    assert ieee[0]["doi"] == "10.1000/abc"
    assert ieee[0]["authors"] == ["A. Smith", "B. Jones"]
    assert ieee[1]["title"] == "Another title"
    assert ieee[1]["year"] == 2020
    apa, apa_warnings = parse_reference_list(APA)
    assert apa_warnings == []
    assert apa[0]["title"] == "A useful title"
    assert apa[0]["year"] == 2021
    assert apa[1]["authors"] == ["Jones, B.", "Lee, C."]


def test_unparsed_block_does_not_invent_a_title():
    records, warnings = parse_reference_list("not a citation at all")
    assert warnings == ["unparsed reference block"]
    assert records[0]["title"] is None
    assert records[0]["year"] is None


def test_grobid_maps_into_the_same_schema_and_wins():
    parsed = references_from_grobid(GROBID)
    assert parsed[0]["title"] == "Confirmed title"
    assert parsed[0]["authors"] == ["Ada Lovelace"]
    assert parsed[0]["year"] == 2021
    assert parsed[0]["venue"] == "Real Journal"
    assert parsed[0]["doi"] == "10.1000/xyz"
    chunks = [
        {"text": "see [1]", "headings": ["Intro"]},
        {"text": IEEE, "headings": ["References"]},
    ]
    attach_references(chunks, section_text(chunks), GROBID)
    assert chunks[0]["references"][0]["title"] == "Confirmed title"
    assert chunks[0]["cited_references"][0]["doi"] == "10.1000/xyz"
    assert chunks[1]["cited_references"] == []


def test_numeric_and_author_year_links():
    records, _warnings = parse_reference_list(IEEE + "\nSmith, A. (2021). A useful title. Real Journal.\n")
    ieee, _ = parse_reference_list(IEEE)
    assert cited_in_text("shown in [1] and [2]", ieee)[0]["title"] == "A useful title"
    assert [item["index"] for item in cited_in_text("see [1-2]", ieee)] == [1, 2]
    named, _ = parse_reference_list(APA)
    linked = cited_in_text("as Smith et al., 2021 later noted", named)
    assert linked[0]["year"] == 2021
    assert cited_in_text("Jones, 2020 agrees", named)[0]["title"] == "Another title"
    assert records
