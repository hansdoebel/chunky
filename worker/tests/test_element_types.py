"""Element-type filters match the primary field or the type array."""

from __future__ import annotations

from chunky_worker.search import PayloadFilter, build_query_filter


def _should_keys(query_filter) -> list[str]:
    return [condition.key for condition in query_filter.must[0].should]


def test_table_and_formula_filters_use_the_shared_filter_object():
    table = build_query_filter([PayloadFilter(key="content_type", match="table")])
    formula = build_query_filter([PayloadFilter(key="content_type", match="formula")])
    picture = build_query_filter([PayloadFilter(key="content_type", match="picture")])
    assert _should_keys(table) == ["content_type", "content_types"]
    assert "table" in table.must[0].should[0].match.any
    assert "table" in table.must[0].should[1].match.any
    assert "formula" in formula.must[0].should[1].match.any
    assert "equation" in formula.must[0].should[0].match.any
    assert "figure" in picture.must[0].should[0].match.any
    assert "picture" in picture.must[0].should[0].match.any
    assert "figure" in picture.must[0].should[1].match.any
    title = build_query_filter([PayloadFilter(key="content_type", match="title")])
    assert "title" in title.must[0].should[0].match.any
    assert "text" in title.must[0].should[0].match.any
    negated = build_query_filter([PayloadFilter(key="content_type", match="picture", negate=True)])
    assert "figure" in negated.must_not[0].should[0].match.any
    grouped = build_query_filter([PayloadFilter(key="content_type", any=["picture"])])
    assert "figure" in grouped.must[0].should[0].match.any
    assert "picture" in grouped.must[0].should[0].match.any


def test_a_non_element_filter_stays_exact():
    query_filter = build_query_filter([PayloadFilter(key="content_type", match="document")])
    assert query_filter.must[0].key == "content_type"
    assert query_filter.must[0].match.value == "document"
