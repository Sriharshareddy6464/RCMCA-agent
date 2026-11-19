"""LangGraph workflow for turning a citizen report into a triaged road issue."""

from __future__ import annotations

import os
import json
from typing import Any, Awaitable, Callable, Literal, TypedDict

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


class ChatIntent(BaseModel):
    """Structured intent parsed from a conversational navigation/issue request."""

    action: Literal["route", "issue", "other"]
    origin: str | None = Field(
        default=None,
        description="Origin place name; use 'current location' when the user says here or my location",
    )
    destination: str | None = Field(default=None, description="Destination place name")
    issue_id: str | None = Field(default=None, description="UUID of the referenced road issue, if present")
    issue_query: str | None = Field(
        default=None,
        description="Short identifying phrase with the issue category and locality, when available",
    )
    language: Literal["en", "te", "hi"] = "en"


class ChatState(TypedDict, total=False):
    message: str
    user_lat: float | None
    user_lon: float | None
    intent: ChatIntent
    route_audit: dict[str, Any]
    issue: dict[str, Any]
    email_draft: ComplaintDraft
    answer: str


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


def build_chat_graph(
    route_auditor: Callable[[ChatIntent, ChatState], Awaitable[dict[str, Any]]],
    issue_resolver: Callable[[ChatIntent, ChatState], Awaitable[dict[str, Any]]],
    chat_model=None,
):
    """Build a conversational intent graph with deterministic route/issue tools.

    The model extracts intent and drafts issue correspondence. Route scoring and
    issue lookup remain application/PostGIS operations supplied by the API.
    """
    llm = chat_model or _model()
    intent_llm = llm.with_structured_output(ChatIntent)
    email_llm = llm.with_structured_output(ComplaintDraft)

    async def interpret_message(state: ChatState) -> dict[str, Any]:
        intent = await intent_llm.ainvoke(
            [
                (
                    "system",
                    "Classify the user's Hyderabad road-monitoring request. Use action=route "
                    "when they ask to travel, navigate, compare a route, or go from one "
                    "place to another. Extract origin and destination as concise place names; "
                    "if they say 'here', 'from my location', or equivalent, set origin to "
                    "'current location'. Use action=issue when they ask about a reported road "
                    "issue or want an inspection/repair complaint; preserve any UUID and "
                    "extract a short category/locality search phrase. Otherwise use action=other. "
                    "Never invent a place name or issue ID. Set language to en, te, or hi.",
                ),
                (
                    "human",
                    json.dumps(
                        {
                            "message": state["message"],
                            "user_location": {
                                "latitude": state.get("user_lat"),
                                "longitude": state.get("user_lon"),
                            },
                        },
                        ensure_ascii=False,
                    ),
                ),
            ]
        )
        return {"intent": ChatIntent.model_validate(intent)}

    async def run_route_audit(state: ChatState) -> dict[str, Any]:
        intent = state["intent"]
        audit = await route_auditor(intent, state)
        return {"route_audit": audit}

    async def find_issue_and_draft_email(state: ChatState) -> dict[str, Any]:
        intent = state["intent"]
        issue = await issue_resolver(intent, state)
        email = await email_llm.ainvoke(
            [
                (
                    "system",
                    "Draft a concise, respectful municipal inspection/repair email using "
                    "only the supplied database issue record. Do not invent a date, street, "
                    "impact, repair history, or official finding. Include the recorded issue "
                    "description, ward, corporation, status, and a request to inspect and take "
                    "appropriate action. Write in the requested language (en=English, "
                    "te=Telugu, hi=Hindi). This is a draft only; do not claim it was sent.",
                ),
                (
                    "human",
                    json.dumps(
                        {"language": intent.language, "issue": issue},
                        ensure_ascii=False,
                        default=str,
                    ),
                ),
            ]
        )
        return {"issue": issue, "email_draft": ComplaintDraft.model_validate(email)}

    def other_response(_state: ChatState) -> dict[str, str]:
        return {
            "answer": (
                "I can compare Hyderabad road routes or look up a reported issue. "
                "For a route, provide a start and destination; for an issue, include "
                "its ID or a category and locality."
            )
        }

    builder = StateGraph(ChatState)
    builder.add_node("interpret_message", interpret_message)
    builder.add_node("route_audit", run_route_audit)
    builder.add_node("issue_lookup_and_email", find_issue_and_draft_email)
    builder.add_node("other_response", other_response)
    builder.add_edge(START, "interpret_message")
    builder.add_conditional_edges(
        "interpret_message",
        lambda state: state["intent"].action,
        {
            "route": "route_audit",
            "issue": "issue_lookup_and_email",
            "other": "other_response",
        },
    )
    builder.add_edge("route_audit", END)
    builder.add_edge("issue_lookup_and_email", END)
    builder.add_edge("other_response", END)
    return builder.compile()


rcmc_app = build_issue_graph()
