"""LangGraph workflow for turning a citizen report into a triaged road issue."""

from __future__ import annotations

import os
import json
from typing import Literal, TypedDict

from langchain_openai import ChatOpenAI
from langgraph.graph import END, START, StateGraph
from pydantic import BaseModel, Field

HazardCategory = Literal[
    "pothole",
    "waterlogging",
    "damaged_surface",
    "open_manhole",
    "broken_divider",
    "other",
]


class IssueFacts(BaseModel):
    """Fields normalized from a resident's free-text report."""

    category: HazardCategory
    severity: int = Field(ge=1, le=5, description="Estimated road hazard severity")
    concise_description: str = Field(min_length=8, max_length=400)
    uncertainty: str = Field(
        description="Important missing or uncertain details; use 'none' when clear"
    )


class ComplaintDraft(BaseModel):
    subject: str = Field(min_length=8, max_length=120)
    body: str = Field(min_length=40, max_length=1500)


class IssueState(TypedDict, total=False):
    description: str
    latitude: float | None
    longitude: float | None
    near_sensitive_site: bool
    language: Literal["en", "te", "hi"]
    facts: IssueFacts
    priority_score: int
    dispatch_tier: Literal["HIGH", "MEDIUM", "LOW"]
    action_required: str
    complaint_subject: str
    complaint_draft: str


def _model():
    """Create a local OpenAI-compatible or AWS Bedrock Converse chat client."""
    provider = os.getenv("LLM_PROVIDER", "openai_compatible").strip().lower()
    if provider == "bedrock":
        from langchain_aws import ChatBedrockConverse

        return ChatBedrockConverse(
            model=os.getenv("LLM_MODEL", "qwen.qwen3-32b-v1:0"),
            region_name=os.getenv("AWS_REGION", "ap-south-1"),
            temperature=0,
        )
    return ChatOpenAI(
        base_url=os.getenv("LLM_BASE_URL", "http://localhost:11434/v1"),
        api_key=os.getenv("LLM_API_KEY", "ollama-local"),
        model=os.getenv("LLM_MODEL", "qwen2.5:3b"),
        temperature=0,
    )


def build_issue_graph(chat_model=None):
    """Build the report normalization and deterministic triage workflow."""
    llm = chat_model or _model()
    structured_llm = llm.with_structured_output(IssueFacts)
    structured_draft_llm = llm.with_structured_output(ComplaintDraft)

    def normalize_report(state: IssueState) -> dict:
        result = structured_llm.invoke(
            [
                (
                    "system",
                    "Normalize a citizen's road hazard report. Classify only into the "
                    "allowed category list. Estimate severity from 1 (minor) to 5 "
                    "(immediate danger), based only on the supplied text. Do not invent "
                    "a location, cause, injury, or fact. If details are unclear, state "
                    "that in uncertainty and use a conservative estimate.",
                ),
                ("human", state["description"]),
            ]
        )
        return {"facts": result}

    def prioritize(state: IssueState) -> dict:
        facts = state["facts"]
        # Transparent rules keep operational priority independent of model prose.
        score = facts.severity * 15
        if facts.category in {"open_manhole", "waterlogging", "broken_divider"}:
            score += 10
        if state.get("near_sensitive_site", False):
            score += 20
        score = min(score, 100)

        if score >= 75:
            tier, action = "HIGH", "Immediate crew inspection"
        elif score >= 45:
            tier, action = "MEDIUM", "Schedule maintenance inspection"
        else:
            tier, action = "LOW", "Monitor and include in routine inspection"

        return {
            "priority_score": score,
            "dispatch_tier": tier,
            "action_required": action,
        }

    def draft_complaint(state: IssueState) -> dict:
        facts = state["facts"]
        details = {
            "category": facts.category,
            "severity_estimate": facts.severity,
            "description": facts.concise_description,
            "uncertainty": facts.uncertainty,
            "latitude": state.get("latitude"),
            "longitude": state.get("longitude"),
        }
        draft = structured_draft_llm.invoke(
            [
                (
                    "system",
                    "Write a concise, respectful municipal road-repair complaint using "
                    "only the provided facts. Do not invent a street name, landmark, "
                    "date, injury, or cause. Ask for inspection and appropriate repair. "
                    "Write the subject and body in the requested language: en=English, "
                    "te=Telugu, hi=Hindi. Severity is an estimate; do not present it "
                    "as an official inspection result.",
                ),
                (
                    "human",
                    json.dumps(
                        {"language": state.get("language", "en"), "report": details},
                        ensure_ascii=False,
                    ),
                ),
            ]
        )
        return {"complaint_subject": draft.subject, "complaint_draft": draft.body}

    builder = StateGraph(IssueState)
    builder.add_node("normalize_report", normalize_report)
    builder.add_node("prioritize", prioritize)
    builder.add_node("draft_complaint", draft_complaint)
    builder.add_edge(START, "normalize_report")
    builder.add_edge("normalize_report", "prioritize")
    builder.add_edge("prioritize", "draft_complaint")
    builder.add_edge("draft_complaint", END)
    return builder.compile()


rcmc_app = build_issue_graph()
