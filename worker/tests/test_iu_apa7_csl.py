from pathlib import Path

import pytest

lxml = pytest.importorskip("lxml")
from lxml import etree

ROOT = Path(__file__).resolve().parents[2]
CSL = ROOT / "Chunky" / "Resources" / "iu-apa7.csl"
SCHEMA = Path(__file__).resolve().parent / "fixtures" / "csl-1.0.2.rng"


def test_iu_apa7_csl_validates_against_csl_1_0_2():
    schema = etree.RelaxNG(etree.parse(str(SCHEMA)))
    document = etree.parse(str(CSL))
    assert schema.validate(document), schema.error_log
    text = CSL.read_text(encoding="utf-8")
    assert 'delimiter-precedes-last="never"' in text
    assert 'demote-non-dropping-particle="never"' in text
    assert 'default-locale="de-DE"' in text
    assert "Hrsg." in text
    assert "Kap." in text
    assert "Aufl." in text
    assert "Vorab-Onlinepublikation" in text
    assert "Januar" in text
    assert "original-date" not in text
    assert "accessed" not in text
