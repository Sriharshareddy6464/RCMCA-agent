"""Offline smoke check for LangGraph routing, scoring, and structured drafting."""

from rcmc_graph import ComplaintDraft, IssueFacts, build_issue_graph


class FakeStructuredModel:
    def __init__(self, schema):
        self.schema = schema

    def invoke(self, _messages):
        if self.schema is IssueFacts:
            return IssueFacts(
                category="waterlogging",
                severity=4,
                concise_description="Water is covering the road near traffic.",
                uncertainty="none",
            )
        return ComplaintDraft(
            subject="Waterlogging on the road",
            body="Please inspect the reported waterlogging and arrange appropriate action.",
        )


class FakeChatModel:
    def with_structured_output(self, schema):
        return FakeStructuredModel(schema)


def main() -> None:
    graph = build_issue_graph(FakeChatModel())
    result = graph.invoke(
        {
            "description": "Water is covering the road and traffic is diverting.",
            "latitude": 17.43,
            "longitude": 78.44,
            "near_sensitive_site": True,
            "language": "te",
        }
    )
    assert result["priority_score"] == 90
    assert result["dispatch_tier"] == "HIGH"
    assert result["complaint_subject"] == "Waterlogging on the road"
    assert "appropriate action" in result["complaint_draft"]
    print("LangGraph normalization/scoring/drafting smoke check passed")


if __name__ == "__main__":
    main()
